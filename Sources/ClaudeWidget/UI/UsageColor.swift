import SwiftUI

/// Shared color thresholds for usage indicators.
enum UsageColor {
    /// `pct` is 0.0 → 1.0.
    static func forPct(_ pct: Double) -> Color {
        switch pct {
        case ..<0.60: return .green
        case ..<0.85: return .orange
        default:      return .red
        }
    }
    /// Convenience overload — `percent` is 0 → 100.
    static func forPercent(_ percent: Double) -> Color {
        forPct(percent / 100.0)
    }
}
