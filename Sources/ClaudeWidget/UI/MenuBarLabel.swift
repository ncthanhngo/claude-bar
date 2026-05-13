import Foundation

/// Formatters for the menu-bar text and other compact representations.
enum MenuBarLabel {

    /// `"23% · 1h47m"` or `"idle"` when no data.
    static func format(_ snapshot: UsageSnapshot) -> String {
        guard snapshot.source != .empty else { return "idle" }
        let pct = Int(snapshot.sessionPercent.rounded())
        return "\(pct)% · \(formatRemaining(snapshot.sessionRemaining))"
    }

    /// `"3h24m"`, `"42m"`, or `"0m"`.
    static func formatRemaining(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s <= 0 { return "0m" }
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 { return "\(h)h\(m.formatted(.number.precision(.integerLength(2))))m" }
        return "\(m)m"
    }

    /// `"31.7M"`, `"450K"`, or `"42"`.
    static func formatTokens(_ count: Int) -> String {
        let n = Double(count)
        switch n {
        case 1_000_000...: return String(format: "%.1fM", n / 1_000_000)
        case 1_000...:     return String(format: "%.1fK", n / 1_000)
        default:           return "\(count)"
        }
    }
}
