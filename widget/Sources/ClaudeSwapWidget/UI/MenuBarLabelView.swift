import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// The text rendered in the macOS menu bar (top of screen).
struct MenuBarLabelView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject private var serverMonitor: ServerMonitorStore
    @EnvironmentObject private var claudeStatus: ClaudeStatusStore
    @EnvironmentObject private var systemMetrics: SystemMetricsStore
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // One pre-rendered bitmap for the whole label; see MenuBarLabelRenderer
        // for why SwiftUI Text/Image siblings don't work in a MenuBarExtra label.
        Image(nsImage: MenuBarLabelRenderer.render(labelSpec))
    }

    private var labelSpec: MenuBarLabelRenderer.Spec {
        var plain = usageSegments
        var tinted: (text: String, color: NSColor)?
        if settings.menuBarShowCPUTemp, let c = systemMetrics.cpuTempC {
            let label = "\(Int(c.rounded()))°C"
            if let color = Self.temperatureColor(c) { tinted = (label, color) } else { plain.append(label) }
        }
        return .init(
            icon: iconImage,
            // Red dot when a monitored server is offline or past the disk crit
            // threshold; severity dot on the opposite corner for a Claude
            // outage so the two can't be mistaken for each other.
            trailingDot: serverHasAlert ? .systemRed : nil,
            leadingDot: claudeStatus.shouldBadge ? NSColor(claudeStatus.tint) : nil,
            plain: plain,
            tinted: tinted)
    }

    /// Heat warning tint: orange from 60°C, dark red from 70°C, else nil.
    static func temperatureColor(_ celsius: Double) -> NSColor? {
        switch celsius {
        case 70...: return NSColor(red: 0.75, green: 0.05, blue: 0.05, alpha: 1)
        case 60...: return .systemOrange
        default:    return nil
        }
    }

    private var serverHasAlert: Bool {
        serverMonitor.healths.contains { h in
            !h.reachable || (h.hasDiskReading && h.diskUsedPct >= settings.serverDiskCritPct)
        }
    }

    /// Bundled icon (tinted per settings) or the SF Symbol fallback.
    private var iconImage: NSImage {
        if let img = scaledMenuBarImage { return img }
        let symbol = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) ?? NSImage()
        guard let tint = settings.menuBarIconColor.color else { return symbol }
        let config = NSImage.SymbolConfiguration(paletteColors: [NSColor(tint)])
        return symbol.withSymbolConfiguration(config) ?? symbol
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

    /// Usage-related label parts per menu-bar style, each metric gated by its
    /// own Settings toggle. Icon-only style contributes nothing.
    private var usageSegments: [String] {
        guard settings.menuBarStyle != .iconOnly else { return [] }
        guard let active else { return ["—"] }
        var parts: [String] = []
        if settings.menuBarStyle == .full { parts.append(active.account.displayName) }
        if let w = fiveHour {
            if settings.menuBarShowUsagePct { parts.append("\(w.percentInt)%") }
            if settings.menuBarShowReset { parts.append(w.resetLabel()) }
        }
        return parts
    }
}
