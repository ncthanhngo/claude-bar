import AppKit

/// On-screen footprint of the Daily window. `max` fills the screen (the
/// original behaviour); `medium` and `small` center a fixed-size card for
/// users who want the briefing as a focused panel rather than a near-
/// fullscreen page. Stored as a raw string in AppSettings.
enum DailyWindowSize: String, CaseIterable, Identifiable {
    case max
    case medium
    case small

    var id: String { rawValue }

    /// Label as shown in the size picker.
    var label: String {
        switch self {
        case .max:    return "Max"
        case .medium: return "Medium"
        case .small:  return "Small"
        }
    }

    /// One-line explanation shown under the picker.
    var detail: String {
        switch self {
        case .max:    return "Fills the screen with a 32px margin — best for reading long briefings."
        case .medium: return "Centered 1180×800 panel — focused but still fits a full plan."
        case .small:  return "Centered 920×620 card — a compact glance window."
        }
    }

    /// Centered frame within a screen's `visibleFrame`. `max` insets the whole
    /// visible area; `medium` / `small` center a target size, clamped so they
    /// never exceed the visible area (minus a small margin) on smaller displays.
    func frame(in visible: NSRect) -> NSRect {
        switch self {
        case .max:
            return visible.insetBy(dx: 32, dy: 32)
        case .medium:
            return Self.centered(width: 1180, height: 800, in: visible)
        case .small:
            return Self.centered(width: 920, height: 620, in: visible)
        }
    }

    private static func centered(width: CGFloat, height: CGFloat, in visible: NSRect) -> NSRect {
        // 64pt total margin keeps a centered card off the screen edges even
        // when the requested size is larger than the display.
        let w = min(width, visible.width - 64)
        let h = min(height, visible.height - 64)
        // Horizontally centered, but biased toward the TOP of the screen rather
        // than vertically centered. AppKit's origin is bottom-left, so "near the
        // top" means a high y — pin the window's top edge ~topGap below the
        // visible top, clamped so it never underflows on short displays.
        let topGap: CGFloat = 40
        let x = visible.midX - w / 2
        // Swift.max — the bare `max` would resolve to the `max` enum case here.
        let y = Swift.max(visible.minY + 32, visible.maxY - h - topGap)
        return NSRect(x: x, y: y, width: w, height: h)
    }
}
