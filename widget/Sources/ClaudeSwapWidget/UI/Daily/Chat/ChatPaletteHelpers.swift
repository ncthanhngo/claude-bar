import SwiftUI

/// Convenience adapters on top of BriefingPalette for chat-specific
/// recurring compositions. Keep these one-liners so styling stays declarative
/// at the call sites and the token set in BriefingPalette stays the source
/// of truth across light / dark / rainbow.
extension BriefingPalette {
    /// Eyebrow uppercase tracking used for "USER · 14:21" labels.
    var chatEyebrowFont: Font {
        .system(size: 10.5, weight: .semibold)
    }

    /// Body font for message text.
    var chatBodyFont: Font {
        .system(size: 15)
    }

    /// Monospace font used in code blocks.
    var chatMonoFont: Font {
        .system(size: 12.5, design: .monospaced)
    }

    /// Soft hairline divider used between rail items + thread sections.
    var hairlineColor: Color { line }

    /// User-bubble background (right-aligned).
    var userBubbleBackground: Color { paper2 }

    /// Token-chip color for healthy quota (< 50%).
    var quotaSageColor: Color { sage }

    /// Token-chip color for warm quota (50-80%).
    var quotaGoldColor: Color { gold }

    /// Token-chip color for hot quota (> 80%).
    var quotaCoralColor: Color { coral }
}

/// Token-by-token formatter for the eyebrow timestamp.
enum ChatTimeFormatter {
    static func short(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// Relative date for the rail (e.g. "hôm nay 14:22", "hôm qua 09:01",
    /// "18/5 16:33"). Tightens visual noise on dense conversation lists.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar(identifier: .gregorian)
        let timePart = short(date)
        if cal.isDateInToday(date) { return "hôm nay \(timePart)" }
        if cal.isDateInYesterday(date) { return "hôm qua \(timePart)" }
        let df = DateFormatter()
        df.dateFormat = "d/M"
        return "\(df.string(from: date)) \(timePart)"
    }
}
