import SwiftUI

/// The text rendered in the macOS menu bar (top of screen).
struct MenuBarLabelView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 4) {
            menuBarIcon
            if settings.menuBarStyle != .iconOnly, let text = labelText {
                Text(text).monospacedDigit()
            }
        }
    }

    private var menuBarIcon: some View {
        Group {
            if let img = scaledMenuBarImage {
                Image(nsImage: img)
            } else {
                // SF Symbol fallback — foregroundColor works fine here
                Image(systemName: iconName)
                    .foregroundColor(settings.menuBarIconColor.color)
            }
        }
    }

    private var scaledMenuBarImage: NSImage? {
        guard let url = Bundle.main.url(forResource: "icon", withExtension: "png"),
              let src = NSImage(contentsOf: url) else { return nil }
        let h: CGFloat = 16
        let w = round(h * src.size.width / src.size.height)
        let size = NSSize(width: w, height: h)
        let rect = NSRect(origin: .zero, size: size)

        if let swiftColor = settings.menuBarIconColor.color {
            // Bake tint into the image directly: draw source, then fill with
            // the chosen color using .sourceAtop (only paints over existing pixels).
            let out = NSImage(size: size)
            out.lockFocus()
            src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            NSColor(swiftColor).setFill()
            rect.fill(using: .sourceAtop)
            out.unlockFocus()
            return out
        } else {
            // System / auto: template lets macOS pick white/black per menu bar appearance.
            let out = NSImage(size: size, flipped: false) { r in
                NSGraphicsContext.current?.imageInterpolation = .none
                src.draw(in: r)
                return true
            }
            out.isTemplate = true
            return out
        }
    }

    private var active: AccountViewDTO? { store.snapshot?.active }

    /// Menu bar shows the 5-hour window only — that is the daily quota the
    /// user actually paces against. The 7-day window is a cap, shown inside
    /// the dropdown instead.
    private var fiveHour: UsageWindowDTO? { active?.usage?.fiveHour }

    private var iconName: String {
        guard let w = fiveHour else { return "person.crop.circle.dashed" }
        switch w.percentInt {
        case ..<50:  return "person.crop.circle.fill"
        case ..<80:  return "person.crop.circle.badge.exclamationmark"
        default:     return "person.crop.circle.badge.exclamationmark.fill"
        }
    }

    private var labelText: String? {
        guard let active else { return "—" }
        let name = active.account.displayName
        guard let w = fiveHour else { return name }
        let pct = w.percentInt
        let reset = w.resetLabel()
        switch settings.menuBarStyle {
        case .iconOnly: return nil
        case .compact:  return "\(pct)% · \(reset)"
        case .full:     return "\(name) · \(pct)% · \(reset)"
        }
    }
}
