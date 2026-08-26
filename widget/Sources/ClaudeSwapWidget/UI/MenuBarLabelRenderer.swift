import AppKit
import SwiftUI

/// Rasterises the whole menu-bar label (icon, alert dots, usage text, CPU
/// temperature) into ONE non-template bitmap.
///
/// Why an image and not SwiftUI views: MenuBarExtra does not host the label
/// as a live view. It extracts an image and a title for the NSStatusBarButton,
/// so any Text is recoloured to the menu-bar tint (no per-segment colour), a
/// second Image is dropped, and a view that first appears after the initial
/// measurement is clipped. A single pre-rendered bitmap sidesteps all three:
/// the button shows exactly these pixels and re-fits its width to the image.
@MainActor
enum MenuBarLabelRenderer {

    struct Spec {
        var icon: NSImage
        /// Small dot at the icon's top-right (server alert), if any.
        var trailingDot: NSColor?
        /// Small dot at the icon's top-left (Claude outage), if any.
        var leadingDot: NSColor?
        /// Text segments in the menu bar's own colour, joined by " · ".
        var plain: [String]
        /// Temperature drawn in a warning colour, appended after `plain`.
        var tinted: (text: String, color: NSColor)?
    }

    private static let iconHeight: CGFloat = 16
    private static let gap: CGFloat = 4
    private static let dotSize: CGFloat = 5

    static func render(_ spec: Spec) -> NSImage {
        let text = attributedText(spec)
        let textSize = text.length > 0 ? text.size() : .zero
        let iconW = round(iconHeight * spec.icon.size.width / max(spec.icon.size.height, 1))
        let width = iconW + (text.length > 0 ? gap + ceil(textSize.width) : 0)
        let height = max(iconHeight, ceil(textSize.height)) + 2   // headroom for the dots

        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high
            let iconRect = NSRect(x: 0, y: (height - iconHeight) / 2, width: iconW, height: iconHeight)
            spec.icon.draw(in: iconRect)
            if let c = spec.trailingDot {
                c.setFill()
                NSBezierPath(ovalIn: NSRect(x: iconRect.maxX - dotSize + 1, y: iconRect.maxY - dotSize + 1,
                                            width: dotSize, height: dotSize)).fill()
            }
            if let c = spec.leadingDot {
                c.setFill()
                NSBezierPath(ovalIn: NSRect(x: iconRect.minX - 1, y: iconRect.maxY - dotSize + 1,
                                            width: dotSize, height: dotSize)).fill()
            }
            if text.length > 0 {
                text.draw(at: NSPoint(x: iconW + gap, y: (height - textSize.height) / 2))
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Base text colour resolved against the status-bar button's appearance,
    /// so it tracks the wallpaper-driven light/dark menu bar, not the app theme.
    private static func menuBarTextColor() -> NSColor {
        let appearance = MenuBarPopoverToggle.findStatusBarButton()?.effectiveAppearance
            ?? NSApp.effectiveAppearance
        var color = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        return color
    }

    private static func attributedText(_ spec: Spec) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let base = menuBarTextColor()
        let str = NSMutableAttributedString()
        if !spec.plain.isEmpty {
            let sep = spec.tinted == nil ? "" : " · "
            str.append(NSAttributedString(string: spec.plain.joined(separator: " · ") + sep,
                                          attributes: [.font: font, .foregroundColor: base]))
        }
        if let tinted = spec.tinted {
            str.append(NSAttributedString(string: tinted.text,
                                          attributes: [.font: font, .foregroundColor: tinted.color]))
        }
        return str
    }
}
