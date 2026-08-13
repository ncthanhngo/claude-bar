import Foundation

/// The two segments of the full popover: the existing Claude dashboard
/// (accounts + auto-swap + token usage) and the new Server health monitor.
enum PopoverTab: String, CaseIterable, Identifiable {
    case claude
    case server

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .server: return "Server"
        }
    }
}
