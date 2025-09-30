import Foundation

/// Notification payload keys used for cross-transport mesh coordination.
enum MeshNotificationUserInfo: String {
    case packet
    case data
    case messageID
}

extension Notification.Name {
    /// Posted whenever the mesh transport refreshes its local peer identity.
    static let meshServiceIdentityUpdated = Notification.Name("chat.bitchat.mesh.identityUpdated")

    /// Posted for every packet that leaves the local mesh transport.
    static let meshServiceDidBroadcastPacket = Notification.Name("chat.bitchat.mesh.didBroadcastPacket")

    /// Posted whenever Wi-Fi Direct donor mode updates its lifecycle state.
    static let wifiDirectDonorStateChanged = Notification.Name("chat.bitchat.wifidirect.donorStateChanged")
}
