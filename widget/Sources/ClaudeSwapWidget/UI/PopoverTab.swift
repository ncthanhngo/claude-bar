import Foundation

/// The segments of the full popover: the Claude dashboard (accounts +
/// auto-swap + token usage), the Server health monitor, and the NetBird
/// machine list with quick SSH, and the Fan speed control.
enum PopoverTab: String, CaseIterable, Identifiable {
    case claude
    case server
    case netbird
    case fan

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .server: return "Server"
        case .netbird: return "NetBird"
        case .fan: return "Fan"
        }
    }
}
