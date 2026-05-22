import Foundation

/// Two body modes for the Daily window: editorial Plan (briefing) vs Chat
/// (OAuth-bound conversation thread). Stored as raw string in AppSettings.
enum DailyMode: String, CaseIterable, Identifiable {
    case plan
    case chat

    var id: String { rawValue }

    /// Label exactly as it appears in the editorial mode switcher — lowercase
    /// for the inactive variant, capitalised for the active one (rendered by
    /// the view via `.italic()` so we don't capitalise here).
    var label: String {
        switch self {
        case .plan: return "Plan"
        case .chat: return "chat"
        }
    }

    static func from(_ raw: String) -> DailyMode {
        DailyMode(rawValue: raw) ?? .plan
    }
}
