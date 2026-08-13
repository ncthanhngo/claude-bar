import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// The text rendered in the macOS menu bar (top of screen).
struct MenuBarLabelView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject private var serverMonitor: ServerMonitorStore
    @EnvironmentObject private var claudeStatus: ClaudeStatusStore
    @EnvironmentObject private var pipelineStore: PipelineStore
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 4) {
            // While any watched GitLab pipeline is running, the bar shows a
            // pipeline indicator; the instant none are active it reverts to
            // the default Claude usage label (with its server/status dots).
            if pipelineStore.anyRunning {
                pipelineIcon
                if settings.menuBarStyle != .iconOnly, let text = pipelineLabel {
                    Text(text).monospacedDigit()
                }
            } else {
                menuBarIcon
                    // Red dot when a monitored server is offline or past the disk
                    // crit threshold — a glanceable alert without opening the popover.
                    .overlay(alignment: .topTrailing) {
                        if serverHasAlert {
                            Circle().fill(Color.red).frame(width: 5, height: 5)
                                .offset(x: 1, y: -1)
                        }
                    }
                    // Severity dot when Claude itself has a major+ outage — kept at
                    // the opposite corner so it can't be mistaken for the server dot.
                    .overlay(alignment: .topLeading) {
                        if claudeStatus.shouldBadge {
                            Circle().fill(claudeStatus.tint).frame(width: 5, height: 5)
                                .offset(x: -1, y: -1)
                        }
                    }
                if settings.menuBarStyle != .iconOnly, let text = labelText {
                    Text(text).monospacedDigit()
                }
            }
        }
    }

    /// Orange spinning-arrows glyph shown while a pipeline is active — distinct
    /// from the default account icon.
    private var pipelineIcon: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .foregroundColor(.orange)
    }

    /// Running-count text paired with `pipelineIcon`, respecting the menu-bar
    /// density preference.
    private var pipelineLabel: String? {
        let n = pipelineStore.runningCount
        switch settings.menuBarStyle {
        case .iconOnly: return nil
        case .compact:  return "\(n) running"
        case .full:     return "\(n) pipeline\(n == 1 ? "" : "s") running"
        }
    }

    private var serverHasAlert: Bool {
        serverMonitor.healths.contains { h in
            !h.reachable || (h.hasDiskReading && h.diskUsedPct >= settings.serverDiskCritPct)
        }
    }

    private var menuBarIcon: some View {
        Group {
            if let img = scaledMenuBarImage {
                Image(nsImage: img)
            } else {
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

        guard let swiftColor = settings.menuBarIconColor.color else {
            // System: draw as original full-color PNG
            return scaled(src, to: size)
        }

        // Custom color: CIColorMonochrome maps luminosity to the chosen hue.
        // Dark pixels (eyes, outline) stay dark; bright pixels (body) get the tint.
        // This preserves contrast so eyes remain visible.
        guard let cgSrc = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return scaled(src, to: size)
        }
        let ns = NSColor(swiftColor).usingColorSpace(.sRGB) ?? NSColor(swiftColor)
        let ci = CIColor(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent)

        let filter = CIFilter.colorMonochrome()
        filter.inputImage = CIImage(cgImage: cgSrc)
        filter.color = ci
        filter.intensity = 1.0

        guard let output = filter.outputImage,
              let tintedCG = CIContext().createCGImage(output, from: output.extent) else {
            return scaled(src, to: size)
        }
        return scaled(NSImage(cgImage: tintedCG, size: src.size), to: size)
    }

    private func scaled(_ src: NSImage, to size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            src.draw(in: rect)
            return true
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
