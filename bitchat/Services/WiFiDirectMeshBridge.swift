#if os(iOS)
import Foundation
import MultipeerConnectivity
import BitLogger

/// Bridges BitChat's BLE mesh packets over Multipeer Connectivity (Wi-Fi Direct).
///
/// The bridge listens for outbound packets from the primary mesh service and
/// relays them over peer-to-peer Wi-Fi. Incoming Wi-Fi frames are decoded back
/// into `BitchatPacket`s and injected into the BLE pipeline so the rest of the
/// application remains unaware of the transport swap.
protocol WiFiDirectMeshBridgeDelegate: AnyObject {
    func bridge(_ bridge: WiFiDirectMeshBridge, didReceiveResource resource: WiFiDirectMeshBridge.ResourceTransfer)
    func bridge(_ bridge: WiFiDirectMeshBridge, didFailToSendResourceWith error: Error)
}

final class WiFiDirectMeshBridge: NSObject {
    struct ResourceTransfer: Identifiable {
        enum MediaType: String {
            case generic
            case image
            case video
        }

        let id: UUID
        let name: String
        let url: URL
        let mediaType: MediaType
        let originatingPeerID: String

        init(id: UUID = UUID(), name: String, url: URL, mediaType: MediaType, originatingPeerID: String) {
            self.id = id
            self.name = name
            self.url = url
            self.mediaType = mediaType
            self.originatingPeerID = originatingPeerID
        }
    }

    weak var delegate: WiFiDirectMeshBridgeDelegate?

    private weak var meshService: BLEService?
    private let workerQueue = DispatchQueue(label: "chat.bitchat.wifidirect")
    private let serviceType = "bchatmesh"

    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var localPeerID: MCPeerID?
    private var isRunning = false

    // Track discovered peer BitChat IDs per Multipeer peer
    private var peerMeshIDs: [MCPeerID: String] = [:]

    // messageID -> (sources, lastSeen)
    private var inboundSources: [String: Set<String>] = [:]
    private var inboundTimestamps: [String: Date] = [:]
    private var outboundResourcePendingPeers: [UUID: Int] = [:]
    private let inboundRetention: TimeInterval = 30
    private var pendingResources: [UUID: (name: String, mediaType: ResourceTransfer.MediaType, origin: String)] = [:]

    init(meshService: BLEService) {
        self.meshService = meshService
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIdentityUpdate(_:)),
            name: .meshServiceIdentityUpdated,
            object: meshService
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePacketBroadcast(_:)),
            name: .meshServiceDidBroadcastPacket,
            object: meshService
        )
    }

    func sendResource(
        at url: URL,
        named name: String,
        mediaType: ResourceTransfer.MediaType,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        workerQueue.async { [weak self] in
            guard let self, let session = self.session else {
                completion?(.failure(NSError(domain: "chat.bitchat.wifi", code: 9, userInfo: [NSLocalizedDescriptionKey: "session not ready"])))
                return
            }

            let targets = session.connectedPeers
            guard !targets.isEmpty else {
                completion?(.failure(NSError(domain: "chat.bitchat.wifi", code: 10, userInfo: [NSLocalizedDescriptionKey: "no connected peers"])))
                return
            }

            let transferID = UUID()
            let resourceToken = "\(transferID.uuidString)::\(name)"
            outboundResourcePendingPeers[transferID] = targets.count
            for peer in targets {
                session.sendResource(at: url, withName: resourceToken, toPeer: peer) { [weak self] error in
                    guard let self else { return }
                    self.workerQueue.async {
                        if let error {
                            let hadPending = self.outboundResourcePendingPeers.removeValue(forKey: transferID) != nil
                            if hadPending {
                                self.delegate?.bridge(self, didFailToSendResourceWith: error)
                                completion?(.failure(error))
                            }
                        } else if var remaining = self.outboundResourcePendingPeers[transferID] {
                            remaining -= 1
                            if remaining <= 0 {
                                self.outboundResourcePendingPeers.removeValue(forKey: transferID)
                                completion?(.success(()))
                            } else {
                                self.outboundResourcePendingPeers[transferID] = remaining
                            }
                        }
                    }
                }
            }

            do {
                let metadata = ResourceTransfer(id: transferID, name: name, url: url, mediaType: mediaType, originatingPeerID: meshService?.myPeerID ?? "")
                let metadataData = try JSONEncoder().encode([
                    "id": metadata.id.uuidString,
                    "name": metadata.name,
                    "type": metadata.mediaType.rawValue,
                    "origin": metadata.originatingPeerID
                ])
                try session.send(metadataData, toPeers: targets, with: .reliable)
            } catch {
                let hadPending = outboundResourcePendingPeers.removeValue(forKey: transferID) != nil
                if hadPending {
                    delegate?.bridge(self, didFailToSendResourceWith: error)
                }
                completion?(.failure(error))
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stop()
    }

    func start() {
        workerQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isRunning else { return }
            self.isRunning = true
            setupSessionLocked()
        }
    }

    func stop() {
        workerQueue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            teardownLocked()
        }
    }

    @objc private func handleIdentityUpdate(_ notification: Notification) {
        workerQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.restartSessionLocked()
        }
    }

    @objc private func handlePacketBroadcast(_ notification: Notification) {
        guard
            let packet = notification.userInfo?[MeshNotificationUserInfo.packet.rawValue] as? BitchatPacket,
            let data = notification.userInfo?[MeshNotificationUserInfo.data.rawValue] as? Data
        else { return }

        workerQueue.async { [weak self] in
            self?.relay(packet: packet, data: data)
        }
    }

    private func relay(packet: BitchatPacket, data: Data) {
        pruneInboundCacheLocked()
        guard let session = session, !session.connectedPeers.isEmpty else { return }
        guard let meshService = meshService else { return }

        let localPeerIDString = meshService.myPeerID
        guard !localPeerIDString.isEmpty else { return }

        let messageID = packet.dedupIdentifier
        let envelopeData: Data
        do {
            envelopeData = try Self.encodeEnvelope(peerID: localPeerIDString, payload: data)
        } catch {
            SecureLogger.error("WiFiDirectMeshBridge failed to encode envelope: \(error)", category: .session)
            return
        }

        let disallowedSources = inboundSources[messageID] ?? []
        let targets = session.connectedPeers.filter { peer in
            guard let remoteID = self.peerMeshIDs[peer] else { return true }
            return !disallowedSources.contains(remoteID)
        }

        guard !targets.isEmpty else { return }

        do {
            try session.send(envelopeData, toPeers: targets, with: .reliable)
        } catch {
            SecureLogger.warning("WiFiDirectMeshBridge send failed: \(error.localizedDescription)", category: .session)
        }
    }

    private func setupSessionLocked() {
        teardownLocked()
        guard let meshService = meshService else { return }
        let peerIDString = meshService.myPeerID
        guard !peerIDString.isEmpty else { return }

        let displayPrefix = String(peerIDString.prefix(15))
        let local = MCPeerID(displayName: "mesh-\(displayPrefix)")
        localPeerID = local

        let session = MCSession(peer: local, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session

        let advertiser = MCNearbyServiceAdvertiser(
            peer: local,
            discoveryInfo: ["peerID": peerIDString],
            serviceType: serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: local, serviceType: serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    private func restartSessionLocked() {
        teardownLocked()
        if isRunning {
            setupSessionLocked()
        }
    }

    private func teardownLocked() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        session?.disconnect()
        session = nil
        peerMeshIDs.removeAll()
        inboundSources.removeAll()
        inboundTimestamps.removeAll()
        pendingResources.removeAll()
        outboundResourcePendingPeers.removeAll()
    }

    private func pruneInboundCacheLocked(now: Date = Date()) {
        for (messageID, timestamp) in inboundTimestamps {
            if now.timeIntervalSince(timestamp) > inboundRetention {
                inboundTimestamps.removeValue(forKey: messageID)
                inboundSources.removeValue(forKey: messageID)
            }
        }
    }

    private func recordInbound(messageID: String, sourcePeerID: String) {
        pruneInboundCacheLocked()
        if inboundSources[messageID] != nil {
            inboundSources[messageID]?.insert(sourcePeerID)
        } else {
            inboundSources[messageID] = [sourcePeerID]
        }
        inboundTimestamps[messageID] = Date()
    }

    private static func encodeEnvelope(peerID: String, payload: Data) throws -> Data {
        guard let peerIDData = peerID.data(using: .utf8), peerIDData.count <= 255 else {
            throw NSError(domain: "chat.bitchat.wifi", code: 1, userInfo: [NSLocalizedDescriptionKey: "peerID too long"])
        }
        var data = Data()
        data.append(1) // version
        data.append(UInt8(peerIDData.count))
        data.append(peerIDData)
        data.append(payload)
        return data
    }

    private static func decodeEnvelope(_ data: Data) throws -> (peerID: String, payload: Data) {
        guard data.count >= 2 else {
            throw NSError(domain: "chat.bitchat.wifi", code: 2, userInfo: [NSLocalizedDescriptionKey: "envelope too short"])
        }
        var idx = data.startIndex
        let version = data[idx]
        guard version == 1 else {
            throw NSError(domain: "chat.bitchat.wifi", code: 3, userInfo: [NSLocalizedDescriptionKey: "unsupported version \(version)"])
        }
        idx = data.index(after: idx)
        let length = Int(data[idx])
        idx = data.index(after: idx)
        guard data.count >= idx + length else {
            throw NSError(domain: "chat.bitchat.wifi", code: 4, userInfo: [NSLocalizedDescriptionKey: "invalid envelope length"])
        }
        let peerIDData = data[idx..<idx+length]
        idx += length
        guard let peerID = String(data: peerIDData, encoding: .utf8) else {
            throw NSError(domain: "chat.bitchat.wifi", code: 5, userInfo: [NSLocalizedDescriptionKey: "invalid peerID encoding"])
        }
        let payload = data[idx...]
        return (peerID, Data(payload))
    }
}

extension WiFiDirectMeshBridge: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        workerQueue.async { [weak self] in
            guard let self else { return }
            if state == .notConnected {
                self.peerMeshIDs.removeValue(forKey: peerID)
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        workerQueue.async { [weak self] in
            guard let self, let meshService = self.meshService else { return }
            do {
                if let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   let idString = metadata["id"],
                   let uuid = UUID(uuidString: idString),
                   let name = metadata["name"],
                   let typeRaw = metadata["type"],
                   let mediaType = ResourceTransfer.MediaType(rawValue: typeRaw),
                   let origin = metadata["origin"] {
                    self.pendingResources[uuid] = (name: name, mediaType: mediaType, origin: origin)
                    self.peerMeshIDs[peerID] = origin
                    return
                }

                let envelope = try Self.decodeEnvelope(data)
                self.peerMeshIDs[peerID] = envelope.peerID
                guard let packet = BitchatPacket.from(envelope.payload) else { return }
                let messageID = packet.dedupIdentifier
                self.recordInbound(messageID: messageID, sourcePeerID: envelope.peerID)
                meshService.ingestExternalPacket(packet, fromPeerID: envelope.peerID)
            } catch {
                SecureLogger.warning("WiFiDirectMeshBridge received invalid payload: \(error.localizedDescription)", category: .session)
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        workerQueue.async { [weak self] in
            guard let self else { return }
            guard error == nil, let localURL else {
                if let error {
                    self.delegate?.bridge(self, didFailToSendResourceWith: error)
                }
                return
            }

            let destinationDir = FileManager.default.temporaryDirectory.appendingPathComponent("WiFiDirect", isDirectory: true)
            try? FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            let components = resourceName.split(separator: "::", maxSplits: 1, omittingEmptySubsequences: false)
            let idComponent = components.first.flatMap { UUID(uuidString: String($0)) }
            let finalName = components.count > 1 ? String(components[1]) : resourceName
            let destinationURL = destinationDir.appendingPathComponent(finalName)
            try? FileManager.default.removeItem(at: destinationURL)
            do {
                try FileManager.default.copyItem(at: localURL, to: destinationURL)
                let meshID = self.peerMeshIDs[peerID] ?? peerID.displayName
                let transfer: ResourceTransfer
                if
                    let idComponent,
                    let metadata = self.pendingResources.removeValue(forKey: idComponent)
                {
                    transfer = ResourceTransfer(id: idComponent, name: metadata.name, url: destinationURL, mediaType: metadata.mediaType, originatingPeerID: metadata.origin)
                } else {
                    transfer = ResourceTransfer(name: finalName, url: destinationURL, mediaType: .generic, originatingPeerID: meshID)
                }
                self.delegate?.bridge(self, didReceiveResource: transfer)
            } catch {
                self.delegate?.bridge(self, didFailToSendResourceWith: error)
            }
        }
    }

    func session(_ session: MCSession, didReceive certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }
}

extension WiFiDirectMeshBridge: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        workerQueue.async { [weak self] in
            guard let self, let session = self.session else {
                invitationHandler(false, nil)
                return
            }
            invitationHandler(true, session)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        SecureLogger.error("WiFiDirectMeshBridge advertiser failed: \(error.localizedDescription)", category: .session)
    }
}

extension WiFiDirectMeshBridge: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        workerQueue.async { [weak self] in
            guard let self, let session = self.session else { return }
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
            if let meshID = info?["peerID"] {
                self.peerMeshIDs[peerID] = meshID
            }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        workerQueue.async { [weak self] in
            self?.peerMeshIDs.removeValue(forKey: peerID)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        SecureLogger.error("WiFiDirectMeshBridge browser failed: \(error.localizedDescription)", category: .session)
    }
}
#endif
