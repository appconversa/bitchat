#if os(iOS)
import Foundation
import NetworkExtension

/// Coordinates "Donor Mode" – a convenience wrapper around NetworkExtension APIs that
/// allows a Wi‑Fi Direct peer to proxy internet connectivity for nearby nodes.
///
/// The class does not ship an embedded Packet Tunnel provider; instead it configures
/// an external provider (declared in the host app's extensions) and exposes a simple
/// lifecycle interface for the rest of the app.
@available(iOS 15.0, *)
final class WiFiDirectDonorModeController {
    struct Configuration: Equatable {
        /// The bundle identifier of the `NEPacketTunnelProvider` extension that
        /// performs actual packet forwarding. This must be declared in the host app.
        let providerBundleIdentifier: String
        /// Optional metadata propagated to the provider during startup.
        let options: [String: NSObject]

        init(providerBundleIdentifier: String, options: [String: NSObject] = [:]) {
            self.providerBundleIdentifier = providerBundleIdentifier
            self.options = options
        }
    }

    enum State: Equatable {
        case idle
        case preparing
        case active
        case stopping
        case failed(String)
    }

    private let queue = DispatchQueue(label: "chat.bitchat.wifidirect.donor")
    private var manager: NETunnelProviderManager?

    private(set) var state: State = .idle {
        didSet {
            if oldValue != state {
                notifyStateChanged()
            }
        }
    }

    func enable(with configuration: Configuration, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard case .idle = self.state else {
                completion(.failure(NSError(domain: "chat.bitchat.donor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Donor mode already active"])) )
                return
            }

            self.state = .preparing
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    self.queue.async {
                        self.state = .failed(error.localizedDescription)
                        completion(.failure(error))
                    }
                    return
                }

                let manager = managers?.first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == configuration.providerBundleIdentifier }) ?? NETunnelProviderManager()
                let protocolConfiguration = NETunnelProviderProtocol()
                protocolConfiguration.providerBundleIdentifier = configuration.providerBundleIdentifier
                protocolConfiguration.providerConfiguration = configuration.options
                protocolConfiguration.disconnectOnSleep = false

                manager.localizedDescription = "BitChat Donor Tunnel"
                manager.protocolConfiguration = protocolConfiguration
                manager.isEnabled = true

                manager.saveToPreferences { error in
                    if let error {
                        self.queue.async {
                            self.state = .failed(error.localizedDescription)
                            completion(.failure(error))
                        }
                        return
                    }

                    manager.loadFromPreferences { loadError in
                        if let loadError {
                            self.queue.async {
                                self.state = .failed(loadError.localizedDescription)
                                completion(.failure(loadError))
                            }
                            return
                        }

                        do {
                            try manager.connection.startVPNTunnel(options: configuration.options)
                            self.queue.async {
                                self.manager = manager
                                self.state = .active
                                completion(.success(()))
                            }
                        } catch {
                            self.queue.async {
                                self.state = .failed(error.localizedDescription)
                                completion(.failure(error))
                            }
                        }
                    }
                }
            }
        }
    }

    func disable(completion: ((Result<Void, Error>) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let manager = self.manager else {
                completion?(.success(()))
                self.state = .idle
                return
            }

            self.state = .stopping
            manager.connection.stopVPNTunnel()
            manager.removeFromPreferences { error in
                self.queue.async {
                    if let error {
                        self.state = .failed(error.localizedDescription)
                        completion?(.failure(error))
                    } else {
                        self.manager = nil
                        self.state = .idle
                        completion?(.success(()))
                    }
                }
            }
        }
    }

    private func notifyStateChanged() {
        NotificationCenter.default.post(name: .wifiDirectDonorStateChanged, object: self, userInfo: ["state": state])
    }
}
@available(iOS 15.0, *)
extension WiFiDirectDonorModeController.State {
    var statusDescription: String {
        switch self {
        case .idle:
            return NSLocalizedString("Donor mode is idle", comment: "Idle donor mode status")
        case .preparing:
            return NSLocalizedString("Preparing donor mode…", comment: "Preparing donor mode status")
        case .active:
            return NSLocalizedString("Donor mode active", comment: "Active donor mode status")
        case .stopping:
            return NSLocalizedString("Stopping donor mode…", comment: "Stopping donor mode status")
        case .failed(let message):
            return message
        }
    }
}
#endif
