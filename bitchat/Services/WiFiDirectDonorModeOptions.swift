#if os(iOS)
import Foundation

/// Strongly typed helper for constructing the provider configuration passed to
/// ``WiFiDirectDonorModeController``.  The options produced here are consumed
/// by the `NEPacketTunnelProvider` shipped with the donor mode extension.  By
/// keeping the keys in one place we avoid fragile stringly‑typed configuration
/// throughout the application.
struct WiFiDirectDonorModeOptions {
    enum OptionKey {
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

    /// The IP or hostname of the donor relay reachable over Wi‑Fi Direct.
    let donorHost: String
    /// The TCP port exposed by the donor relay.
    let donorPort: UInt16
    /// The IPv4 address assigned to the local tunnel interface.
    let tunnelIPv4Address: String
    /// The IPv4 subnet mask for the local tunnel interface.
    let tunnelIPv4SubnetMask: String
    /// Optional explicit gateway for the remote tunnel endpoint.  Defaults to
    /// ``donorHost`` when omitted.
    let remoteIPv4Gateway: String?
    /// Optional IPv6 address for the tunnel interface.
    let tunnelIPv6Address: String?
    /// Optional IPv6 prefix length for the tunnel interface.
    let tunnelIPv6PrefixLength: Int?
    /// DNS resolvers advertised to the system while the tunnel is active.
    let dnsServers: [String]
    /// Custom MTU to apply to the tunnel.
    let mtu: Int?
    /// Interval (in seconds) between keep alive frames sent to the donor.
    let keepAliveInterval: TimeInterval?
    /// Arbitrary metadata forwarded to the donor during the handshake.
    let handshakeMetadata: [String: String]
    /// Whether the tunnel should install a default route that captures all
    /// device traffic.
    let routeAllTraffic: Bool

    init(
        donorHost: String,
        donorPort: UInt16,
        tunnelIPv4Address: String = "10.242.0.2",
        tunnelIPv4SubnetMask: String = "255.255.255.0",
        remoteIPv4Gateway: String? = nil,
        tunnelIPv6Address: String? = nil,
        tunnelIPv6PrefixLength: Int? = nil,
        dnsServers: [String] = ["1.1.1.1", "9.9.9.9"],
        mtu: Int? = 1380,
        keepAliveInterval: TimeInterval? = 30,
        handshakeMetadata: [String: String] = [:],
        routeAllTraffic: Bool = true
    ) {
        self.donorHost = donorHost
        self.donorPort = donorPort
        self.tunnelIPv4Address = tunnelIPv4Address
        self.tunnelIPv4SubnetMask = tunnelIPv4SubnetMask
        self.remoteIPv4Gateway = remoteIPv4Gateway
        self.tunnelIPv6Address = tunnelIPv6Address
        self.tunnelIPv6PrefixLength = tunnelIPv6PrefixLength
        self.dnsServers = dnsServers
        self.mtu = mtu
        self.keepAliveInterval = keepAliveInterval
        self.handshakeMetadata = handshakeMetadata
        self.routeAllTraffic = routeAllTraffic
    }

    /// Converts the strongly typed representation into the dictionary expected
    /// by `NEPacketTunnelProvider`.  All values are coerced into property list
    /// compatible types to satisfy the NetworkExtension requirements.
    func asProviderConfiguration() throws -> [String: NSObject] {
        var configuration: [String: NSObject] = [
            OptionKey.donorHost: donorHost as NSString,
            OptionKey.donorPort: NSNumber(value: donorPort),
            OptionKey.tunnelIPv4Address: tunnelIPv4Address as NSString,
            OptionKey.tunnelIPv4SubnetMask: tunnelIPv4SubnetMask as NSString,
            OptionKey.routeAllTraffic: NSNumber(value: routeAllTraffic)
        ]

        if let remoteIPv4Gateway {
            configuration[OptionKey.remoteIPv4Gateway] = remoteIPv4Gateway as NSString
        }
        if let tunnelIPv6Address, let tunnelIPv6PrefixLength {
            configuration[OptionKey.tunnelIPv6Address] = tunnelIPv6Address as NSString
            configuration[OptionKey.tunnelIPv6PrefixLength] = NSNumber(value: tunnelIPv6PrefixLength)
        }
        if !dnsServers.isEmpty {
            configuration[OptionKey.dnsServers] = dnsServers as NSArray
        }
        if let mtu {
            configuration[OptionKey.mtu] = NSNumber(value: mtu)
        }
        if let keepAliveInterval {
            configuration[OptionKey.keepAliveInterval] = NSNumber(value: keepAliveInterval)
        }
        if !handshakeMetadata.isEmpty {
            let json = try JSONSerialization.data(withJSONObject: handshakeMetadata, options: [])
            configuration[OptionKey.handshakeMetadata] = json as NSData
        }

        return configuration
    }
}
#endif
