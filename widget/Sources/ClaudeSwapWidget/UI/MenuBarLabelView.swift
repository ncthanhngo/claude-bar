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
        let tint = settings.menuBarIconColor.color
        return Group {
            if let img = scaledMenuBarImage {
                Image(nsImage: img)
                    .renderingMode(.template)
                    .foregroundColor(tint)
            } else {
                Image(systemName: iconName)
                    .foregroundColor(tint)
            }
        }
    }

    private var scaledMenuBarImage: NSImage? {
        guard let url = Bundle.main.url(forResource: "icon", withExtension: "png"),
              let src = NSImage(contentsOf: url) else { return nil }
        let h: CGFloat = 16
        let w = round(h * src.size.width / src.size.height)
        let out = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .none
            src.draw(in: rect)
            return true
        }
        out.isTemplate = true
        return out
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
