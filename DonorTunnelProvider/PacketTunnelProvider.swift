#if os(iOS)
import Darwin
import Foundation
import Network
import NetworkExtension
import os.log

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private enum FrameType: UInt8 {
        case packet = 0x01
        case handshake = 0x02
        case keepAlive = 0x03
        case acknowledgment = 0x04
        case error = 0x05
    }

    private let logger = Logger(subsystem: "chat.bitchat.donor", category: "tunnel")
    private let workerQueue = DispatchQueue(label: "chat.bitchat.donor.tunnel")
    private var connection: NWConnection?
    private var configuration: DonorTunnelConfiguration?
    private var startCompletion: ((Error?) -> Void)?
    private var receiveBuffer = Data()
    private var keepAliveTimer: DispatchSourceTimer?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        workerQueue.async { [weak self] in
            guard let self else { return }
            do {
                let startupOptions = Self.normalize(options: options)
                let providerProtocol = self.protocolConfiguration as? NETunnelProviderProtocol
                let configuration = try DonorTunnelConfiguration(
                    providerConfiguration: providerProtocol?.providerConfiguration,
                    startupOptions: startupOptions
                )

                self.configuration = configuration
                self.startCompletion = completionHandler

                self.logger.log("Configuring tunnel for host \(configuration.donorHost, privacy: .public):\(configuration.donorPort)")
                let networkSettings = configuration.makeNetworkSettings()
                self.setTunnelNetworkSettings(networkSettings) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.logger.error("Failed to apply tunnel network settings: \(error.localizedDescription, privacy: .public)")
                        self.finishStart(with: error)
                        return
                    }
                    self.establishConnection()
                }
            } catch {
                self.logger.error("Invalid donor configuration: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        workerQueue.async { [weak self] in
            guard let self else {
                completionHandler()
                return
            }

            self.logger.log("Stopping donor tunnel: reason=\(reason.rawValue)")
            self.startCompletion = nil
            self.keepAliveTimer?.cancel()
            self.keepAliveTimer = nil
            self.connection?.cancel()
            self.connection = nil
            self.configuration = nil
            self.receiveBuffer.removeAll(keepingCapacity: false)
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        workerQueue.async { [weak self] in
            guard let self else {
                completionHandler?(nil)
                return
            }

            guard let configuration = self.configuration else {
                completionHandler?(nil)
                return
            }

            self.logger.log("Received app message with \(messageData.count) bytes")
            // Forward messages from the host app to the donor as out-of-band
            // control signals.  These are framed as handshake packets so the
            // donor can treat them as metadata updates.
            self.sendFrame(type: .handshake, payload: messageData)
            if configuration.keepAliveInterval != nil {
                self.resetKeepAliveTimer()
            }
            completionHandler?(Data())
        }
    }

    // MARK: - Connection lifecycle

    private func establishConnection() {
        guard let configuration else {
            finishStart(with: DonorTunnelError.invalidConfiguration("Missing donor configuration"))
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.prohibitConstrainedPaths = false

        let connection = NWConnection(host: configuration.donorHost, port: configuration.donorPort, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.workerQueue.async {
                switch state {
                case .ready:
                    self.logger.log("Donor connection ready")
                    self.startPacketForwarding()
                    self.scheduleReceive()
                    self.sendInitialHandshake()
                    self.startKeepAliveTimerIfNeeded()
                    self.finishStart(with: nil)
                case .failed(let error):
                    self.logger.error("Donor connection failed: \(error.localizedDescription, privacy: .public)")
                    self.handleConnectionFailure(error)
                case .waiting(let error):
                    self.logger.warning("Donor connection waiting: \(String(describing: error), privacy: .public)")
                case .cancelled:
                    self.logger.log("Donor connection cancelled")
                    self.handleConnectionFailure(nil)
                default:
                    break
                }
            }
        }

        self.connection = connection
        connection.start(queue: workerQueue)
    }

    private func handleConnectionFailure(_ error: Error?) {
        if let startCompletion {
            self.startCompletion = nil
            startCompletion(error ?? DonorTunnelError.connectionFailed("Unable to connect to donor"))
            return
        }

        let nsError: NSError
        if let error = error as NSError? {
            nsError = error
        } else {
            nsError = NSError(domain: "chat.bitchat.donor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Donor connection closed"])
        }
        cancelTunnelWithError(nsError)
    }

    private func finishStart(with error: Error?) {
        if let completion = startCompletion {
            startCompletion = nil
            completion(error)
        } else if let error {
            cancelTunnelWithError(error)
        }
    }

    // MARK: - Packet forwarding

    private func startPacketForwarding() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            if packets.isEmpty {
                self.startPacketForwarding()
                return
            }

            self.workerQueue.async {
                for packet in packets {
                    self.sendPacket(packet)
                }
            }

            self.startPacketForwarding()
        }
    }

    private func sendPacket(_ packet: Data) {
        guard let connection else { return }
        var payload = Data(capacity: packet.count)
        payload.append(packet)
        sendFrame(type: .packet, payload: payload, on: connection)
    }

    private func scheduleReceive() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.workerQueue.async {
                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.processInboundBuffer()
                }

                if let error {
                    self.logger.error("Receive error: \(error.localizedDescription, privacy: .public)")
                    self.handleConnectionFailure(error)
                    return
                }

                if isComplete {
                    self.logger.log("Donor connection signalled completion")
                    self.handleConnectionFailure(nil)
                    return
                }

                self.scheduleReceive()
            }
        }
    }

    private func processInboundBuffer() {
        while receiveBuffer.count >= 5 {
            let lengthData = receiveBuffer.prefix(4)
            let payloadLength = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let totalLength = Int(payloadLength) + 4
            guard receiveBuffer.count >= totalLength else { return }

            let frameData = receiveBuffer.subdata(in: 4..<totalLength)
            receiveBuffer.removeSubrange(0..<totalLength)

            guard let frameTypeRaw = frameData.first,
                  let frameType = FrameType(rawValue: frameTypeRaw) else {
                logger.error("Received frame with unknown type")
                continue
            }

            let payload = frameData.dropFirst()
            switch frameType {
            case .packet:
                deliverPacket(Data(payload))
            case .handshake:
                logger.log("Received donor handshake update of \(payload.count) bytes")
            case .keepAlive:
                logger.log("Received keep alive from donor")
                resetKeepAliveTimer()
            case .acknowledgment:
                logger.log("Received acknowledgment from donor")
            case .error:
                let message = String(data: payload, encoding: .utf8) ?? "Unknown error"
                logger.error("Donor reported error: \(message, privacy: .public)")
            }
        }
    }

    private func deliverPacket(_ packet: Data) {
        guard !packet.isEmpty else { return }
        let protocolNumber: NSNumber
        if let firstByte = packet.first {
            let version = (firstByte & 0xF0) >> 4
            if version == 6 {
                protocolNumber = NSNumber(value: AF_INET6)
            } else {
                protocolNumber = NSNumber(value: AF_INET)
            }
        } else {
            protocolNumber = NSNumber(value: AF_INET)
        }

        packetFlow.writePackets([packet], withProtocols: [protocolNumber])
    }

    private func sendInitialHandshake() {
        guard let configuration else { return }
        var handshakePayload: [String: Any] = [:]
        if let metadata = configuration.handshakeMetadata {
            if let json = try? JSONSerialization.jsonObject(with: metadata, options: []) {
                handshakePayload["metadata"] = json
            }
        }
        if let startup = configuration.startupOptions, !startup.isEmpty {
            handshakePayload["startup_options"] = startup
        }

        guard !handshakePayload.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: handshakePayload, options: []) else {
            return
        }

        sendFrame(type: .handshake, payload: data)
    }

    private func startKeepAliveTimerIfNeeded() {
        guard let interval = configuration?.keepAliveInterval, interval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: workerQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.sendFrame(type: .keepAlive, payload: Data())
        }
        timer.resume()
        keepAliveTimer = timer
    }

    private func resetKeepAliveTimer() {
        guard let interval = configuration?.keepAliveInterval, interval > 0 else { return }
        keepAliveTimer?.schedule(deadline: .now() + interval, repeating: interval)
    }

    private func sendFrame(type: FrameType, payload: Data, on connection: NWConnection? = nil) {
        guard let connection = connection ?? self.connection else { return }
        var frame = Data()
        var length = UInt32(payload.count + 1).bigEndian
        frame.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
        frame.append(type.rawValue)
        frame.append(payload)

        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.logger.error("Failed to send frame: \(error.localizedDescription, privacy: .public)")
                self?.handleConnectionFailure(error)
            }
        })
    }

    // MARK: - Helpers

    private static func normalize(options: [String: NSObject]?) -> [String: Any]? {
        guard let options else { return nil }
        var normalized: [String: Any] = [:]
        for (key, value) in options {
            if let string = value as? String {
                normalized[key] = string
            } else if let number = value as? NSNumber {
                normalized[key] = number
            } else if let data = value as? Data {
                normalized[key] = data.base64EncodedString()
            } else if let array = value as? [Any] {
                normalized[key] = array
            } else if let dict = value as? [String: Any] {
                normalized[key] = dict
            }
        }
        return normalized.isEmpty ? nil : normalized
    }
}
#endif
