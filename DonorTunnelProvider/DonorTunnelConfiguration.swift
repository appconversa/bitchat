#if os(iOS)
import Foundation
import Network
import NetworkExtension

struct DonorTunnelConfiguration {
    struct Keys {
        static let donorHost = "donor_host"
        static let donorPort = "donor_port"
        static let tunnelIPv4Address = "tunnel_ipv4_address"
        static let tunnelIPv4SubnetMask = "tunnel_ipv4_subnet_mask"
        static let remoteIPv4Gateway = "remote_ipv4_gateway"
        static let tunnelIPv6Address = "tunnel_ipv6_address"
        static let tunnelIPv6PrefixLength = "tunnel_ipv6_prefix_length"
        static let dnsServers = "dns_servers"
        static let mtu = "mtu"
        static let keepAliveInterval = "keep_alive_interval"
        static let handshakeMetadata = "handshake_metadata"
        static let routeAllTraffic = "route_all_traffic"
    }

    let donorHost: NWEndpoint.Host
    let donorPort: NWEndpoint.Port
    let remoteAddress: String
    let ipv4Address: String
    let ipv4SubnetMask: String
    let shouldRouteAllTraffic: Bool
    let dnsServers: [String]
    let mtu: Int?
    let keepAliveInterval: TimeInterval?
    let handshakeMetadata: Data?
    let ipv6Address: String?
    let ipv6PrefixLength: Int?
    let startupOptions: [String: Any]?

    init(providerConfiguration: [String: Any]?, startupOptions: [String: Any]?) throws {
        guard let providerConfiguration else {
            throw DonorTunnelError.invalidConfiguration("Missing provider configuration")
        }

        guard let hostString = providerConfiguration[Keys.donorHost] as? String, !hostString.isEmpty else {
            throw DonorTunnelError.invalidConfiguration("Donor host is missing")
        }
        guard let portValue = (providerConfiguration[Keys.donorPort] as? NSNumber)?.uint16Value,
              let port = NWEndpoint.Port(rawValue: portValue) else {
            throw DonorTunnelError.invalidConfiguration("Donor port is missing or invalid")
        }

        let ipv4Address = (providerConfiguration[Keys.tunnelIPv4Address] as? String) ?? "10.242.0.2"
        let ipv4Mask = (providerConfiguration[Keys.tunnelIPv4SubnetMask] as? String) ?? "255.255.255.0"
        let remoteAddress = (providerConfiguration[Keys.remoteIPv4Gateway] as? String) ?? hostString
        let dnsServers = providerConfiguration[Keys.dnsServers] as? [String] ?? []
        let mtu = (providerConfiguration[Keys.mtu] as? NSNumber)?.intValue
        let keepAliveInterval = (providerConfiguration[Keys.keepAliveInterval] as? NSNumber)?.doubleValue
        let handshakeMetadata = providerConfiguration[Keys.handshakeMetadata] as? Data
        let ipv6Address = providerConfiguration[Keys.tunnelIPv6Address] as? String
        let ipv6PrefixLength = (providerConfiguration[Keys.tunnelIPv6PrefixLength] as? NSNumber)?.intValue
        let routeAll = (providerConfiguration[Keys.routeAllTraffic] as? NSNumber)?.boolValue ?? true

        self.donorHost = NWEndpoint.Host(hostString)
        self.donorPort = port
        self.remoteAddress = remoteAddress
        self.ipv4Address = ipv4Address
        self.ipv4SubnetMask = ipv4Mask
        self.dnsServers = dnsServers
        self.mtu = mtu
        self.keepAliveInterval = keepAliveInterval
        self.handshakeMetadata = handshakeMetadata
        self.ipv6Address = ipv6Address
        self.ipv6PrefixLength = ipv6PrefixLength
        self.shouldRouteAllTraffic = routeAll
        self.startupOptions = startupOptions
    }

    func makeNetworkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)

        let ipv4Settings = NEIPv4Settings(addresses: [ipv4Address], subnetMasks: [ipv4SubnetMask])
        if shouldRouteAllTraffic {
            ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        }
        settings.ipv4Settings = ipv4Settings

        if let ipv6Address, let prefix = ipv6PrefixLength {
            let ipv6Settings = NEIPv6Settings(addresses: [ipv6Address], networkPrefixLengths: [NSNumber(value: prefix)])
            if shouldRouteAllTraffic {
                ipv6Settings.includedRoutes = [NEIPv6Route.default()]
            }
            settings.ipv6Settings = ipv6Settings
        }

        if !dnsServers.isEmpty {
            let dnsSettings = NEDNSSettings(servers: dnsServers)
            dnsSettings.matchDomains = [""]
            settings.dnsSettings = dnsSettings
        }

        if let mtu {
            settings.mtu = NSNumber(value: mtu)
        }

        return settings
    }
}

enum DonorTunnelError: Error {
    case invalidConfiguration(String)
    case connectionFailed(String)
}

extension DonorTunnelError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .connectionFailed(let message):
            return message
        }
    }
}
#endif
