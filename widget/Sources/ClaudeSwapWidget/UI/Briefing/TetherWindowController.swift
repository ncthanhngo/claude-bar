import AppKit
import SwiftUI

/// Thin transparent NSWindow rendered between the menu-bar icon and the
/// Daily Briefing window. Draws a tapered line + two pearls so the user sees
/// the briefing originates from the Claude Bar widget.
@MainActor
final class TetherWindowController {
    static let shared = TetherWindowController()

    private var window: NSWindow?

    /// Show the tether anchored to the current status item position and the
    /// passed briefing window. Idempotent — multiple show() calls update
    /// the frame instead of stacking.
    func show(below briefing: NSWindow, palette: BriefingPalette) {
        guard let frame = computeFrame(briefing: briefing) else { return }

        if let w = window {
            w.setFrame(frame, display: true)
            w.orderFrontRegardless()
            return
        }

        let w = NSWindow(contentRect: frame,
                         styleMask: .borderless,
                         backing: .buffered,
                         defer: false)
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: TetherView(palette: palette))
        w.alphaValue = 0
        w.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            w.animator().alphaValue = 1.0
        })

        self.window = w
    }

    func hide() {
        guard let w = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            w.orderOut(nil)
            self?.window = nil
        })
    }

    // MARK: - Frame math

    /// Frame for the halo. Wider than the icon to spread radiance outward,
    /// spans the full gap between the briefing window's top and the icon.
    private func computeFrame(briefing: NSWindow) -> NSRect? {
        guard let icon = MenuBarPopoverToggle.statusItemScreenFrame() else { return nil }
        let topY = icon.minY
        let bottomY = briefing.frame.maxY
        let gap = topY - bottomY
        guard gap > 4 else { return nil }
        // Halo extends ~16px above the briefing's top edge for the bloom to
        // overlap visually with the window's top accent line. Width 360px so
        // radiance fans out beyond the icon column.
        let width: CGFloat = 360
        let height: CGFloat = gap + 18
        let x = icon.midX - width / 2
        let y = bottomY - 6
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

/// Soft warm aura emanating upward from the briefing window's top edge.
/// No hard line — just radiance, like candlelight on parchment.
struct TetherView: View {
    let palette: BriefingPalette

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Wide soft bloom — the "halo" itself. Strongest just above
                // the briefing's top edge, fades to nothing toward the icon.
                RadialGradient(
                    colors: [
                        palette.coral.opacity(0.55),
                        palette.coral.opacity(0.18),
                        palette.coral.opacity(0.04),
                        .clear
                    ],
                    center: .init(x: 0.5, y: 0.95),
                    startRadius: 0,
                    endRadius: geo.size.width * 0.55
                )
                .blendMode(.plusLighter)

                // Thin warm accent kissing the top of the briefing — anchors
                // the halo to a visible edge rather than floating in space.
                LinearGradient(
                    colors: [.clear, palette.coral.opacity(0.0), palette.coral.opacity(0.70)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 2)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .bottom)

                // Three subtle motes that hint at where the radiance came
                // from — small, low-opacity, scattered just below the icon.
                ZStack {
                    Circle()
                        .fill(palette.coral.opacity(0.30))
                        .frame(width: 5, height: 5)
                        .position(x: geo.size.width / 2 - 14, y: 10)
                        .blur(radius: 1.5)
                    Circle()
                        .fill(palette.coral.opacity(0.50))
                        .frame(width: 4, height: 4)
                        .position(x: geo.size.width / 2 + 4, y: 6)
                        .blur(radius: 1.0)
                    Circle()
                        .fill(palette.coral.opacity(0.25))
                        .frame(width: 6, height: 6)
                        .position(x: geo.size.width / 2 + 18, y: 12)
                        .blur(radius: 2.0)
                }
            }
        }
        // Light blur softens any banding in the radial gradient.
        .blur(radius: 0.6)
    }
}
