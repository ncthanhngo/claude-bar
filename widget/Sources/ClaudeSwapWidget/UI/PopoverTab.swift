import Foundation

/// The segments of the full popover: the Claude dashboard (accounts +
/// auto-swap + token usage), the Server health monitor, and the NetBird
/// machine list with quick SSH.
enum PopoverTab: String, CaseIterable, Identifiable {
    case claude
    case server
    case netbird

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .server: return "Server"
        case .netbird: return "NetBird"
        }
    }
}
