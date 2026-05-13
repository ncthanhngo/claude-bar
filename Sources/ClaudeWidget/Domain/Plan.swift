import Foundation

/// Claude subscription plans. Token limits are 5h-block heuristics (configurable).
/// Defaults align with ccusage's published reference figures for combined I/O+cache.
enum Plan: String, CaseIterable, Codable, Identifiable {
    case pro
    case max5
    case max20
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pro:    return "Pro"
        case .max5:   return "Max 5×"
        case .max20:  return "Max 20×"
        case .custom: return "Custom"
        }
    }

    /// Default total-token budget per 5h block.
    var defaultTokenLimit: Int {
        switch self {
        case .pro:    return 19_000_000
        case .max5:   return 88_000_000
        case .max20:  return 220_000_000
        case .custom: return 50_000_000
        }
    }
}
