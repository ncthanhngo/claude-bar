import AppKit
import SwiftUI

/// Thin transparent NSWindow rendered between the menu-bar icon and the
/// Daily Briefing window. Draws a cone-shaped light beam projecting from
/// the menu-bar icon down to the page, so the briefing visibly originates
/// from the Claude Bar widget. Persists for the lifetime of the window.
@MainActor
final class TetherWindowController {
    static let shared = TetherWindowController()

    private var window: NSWindow?
    /// References kept so the tracking timer can re-derive geometry whenever
    /// the icon's screen position shifts (other menu-bar apps appearing /
    /// disappearing, screen resolution changes, etc.).
    private weak var briefing: NSWindow?
    private var beamColor: Color = .primary
    private var lastFrame: NSRect = .zero
    private var trackTimer: Timer?

    /// Show the tether anchored to the current status item position and the
    /// passed briefing window. Idempotent — multiple show() calls update
    /// the frame instead of stacking.
    func show(below briefing: NSWindow, beamColor: Color) {
        self.briefing = briefing
        self.beamColor = beamColor
        guard let geom = computeGeometry(briefing: briefing) else { return }

        if let w = window {
            w.setFrame(geom.frame, display: true)
            lastFrame = geom.frame
            (w.contentView as? NSHostingView<TetherView>)?.rootView =
                TetherView(beamColor: beamColor, iconCenterY: geom.iconCenterY)
            w.orderFrontRegardless()
            startTracking()
            return
        }

        let w = NSWindow(contentRect: geom.frame,
                         styleMask: .borderless,
                         backing: .buffered,
                         defer: false)
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        // `.statusBar` so the beam renders OVER the menu-bar area too —
        // without this the lamp anchored to the icon gets clipped by the
        // system menu bar (which sits above `.floating` windows). The popover
        // (popUpMenu, ~level 101) is still well above this so the popover
        // ordering fix from the Daily window stays intact, and this is a
        // separate window from Daily so Mission-Control swipes are unaffected.
        w.level = .statusBar
        w.ignoresMouseEvents = true
        // Stay on the Space where the briefing was opened — `.canJoinAllSpaces`
        // would leave the beam visible on Spaces that don't contain Daily.
        w.collectionBehavior = []
        w.contentView = NSHostingView(
            rootView: TetherView(beamColor: beamColor, iconCenterY: geom.iconCenterY)
        )
        w.alphaValue = 0
        w.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            w.animator().alphaValue = 1.0
        })

        self.window = w
        self.lastFrame = geom.frame
        startTracking()
    }

    func hide() {
        stopTracking()
        guard let w = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            w.orderOut(nil)
            self?.window = nil
            self?.briefing = nil
        })
    }

    // MARK: - Icon tracking

    /// Poll the icon's screen position so the beam follows the menu-bar icon
    /// when it shifts (other status items joining, system reflow, display
    /// change). Status items don't post KVO/notifications when neighbours
    /// resize, so a lightweight 0.2s timer is the simplest robust option.
    private func startTracking() {
        stopTracking()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshGeometry() }
        }
        RunLoop.main.add(t, forMode: .common)
        trackTimer = t
    }

    private func stopTracking() {
        trackTimer?.invalidate()
        trackTimer = nil
    }

    /// Re-derive the tether frame from the current icon + briefing position.
    /// Cheap to call: bails out when the frame hasn't changed.
    private func refreshGeometry() {
        guard let w = window, let briefing else { return }
        guard let geom = computeGeometry(briefing: briefing) else { return }
        // setFrame triggers redraw; only do it when the icon actually moved.
        if geom.frame != lastFrame {
            w.setFrame(geom.frame, display: true)
            lastFrame = geom.frame
            (w.contentView as? NSHostingView<TetherView>)?.rootView =
                TetherView(beamColor: beamColor, iconCenterY: geom.iconCenterY)
        }
    }

    // MARK: - Frame math

    /// Frame for the beam plus the source point (icon center) expressed in
    /// SwiftUI top-down coords inside the tether view. The window covers the
    /// full icon so the source spark can sit exactly on the icon's image,
    /// not just below it.
    private func computeGeometry(briefing: NSWindow) -> (frame: NSRect, iconCenterY: CGFloat)? {
        // Anchor to just the icon graphic, NOT the full status-button frame —
        // when the menu-bar style is .compact / .full the button also contains
        // text like "9% · 1h 59m" and `icon.midX` would land on the text.
        guard let icon = MenuBarPopoverToggle.iconImageScreenFrame() else { return nil }
        let bottomY = briefing.frame.maxY
        // Anchor the tether window's TOP edge a fixed distance above the
        // icon's geometric center. Using `icon.midY` (not `icon.minY` + height)
        // is robust against reflection returning a view whose bounds height
        // doesn't match the visible icon — `midY` from the full status-item
        // frame always lands at the icon's vertical center.
        // Extend the window well above the icon (24pt) so the lamp's full
        // glow renders inside / above the menu bar without clipping — paired
        // with `level = .statusBar` so those pixels actually paint over the
        // menu-bar area instead of being hidden behind it.
        let topMargin: CGFloat = 24      // SwiftUI y of icon center → apex sits here
        let bottomOverlap: CGFloat = 6   // sink beam slightly into briefing top
        let windowTopScreenY = icon.midY + topMargin
        let windowBottomScreenY = bottomY - bottomOverlap
        let height = windowTopScreenY - windowBottomScreenY
        guard height > 4 else { return nil }
        let width: CGFloat = 420
        let x = icon.midX - width / 2
        // SwiftUI top-down: y=0 = window top edge = icon.midY + topMargin in
        // screen coords. So y=topMargin in SwiftUI = icon.midY in screen.
        return (
            NSRect(x: x, y: windowBottomScreenY, width: width, height: height),
            topMargin
        )
    }
}

/// Cone-shaped light beam projecting from the menu-bar icon down onto the
/// briefing window — like a spotlight or projector beam. Built in layers:
/// outer halo (soft, wide), main beam (medium), bright core (narrow), and
/// a hot spark at the icon source.
struct TetherView: View {
    /// Color of the beam — matches the menu-bar icon tint so the light
    /// visibly originates from the icon.
    let beamColor: Color
    /// Y coord (SwiftUI top-down) of the icon's center inside the view —
    /// the apex of the light cone.
    let iconCenterY: CGFloat

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let bottomWidth = min(w * 0.72, 300)
            // Apex sits at the icon's geometric center, then nudged right and
            // up to hug the icon's image more snugly (the image is offset
            // from the button bounding center in practice).
            let apexX = w / 2 + 11
            let apexY = iconCenterY + 10
            // Gradient starts at the apex, not at the top of the window.
            let beamStart = UnitPoint(
                x: max(0, min(1, apexX / w)),
                y: max(0, min(1, apexY / h))
            )
            let beamEnd = UnitPoint(x: max(0, min(1, apexX / w)), y: 1.0)

            ZStack {
                // Outer halo — wide, soft, bleeds light around the cone.
                beamPath(w: w, h: h, top: 40, bottom: bottomWidth * 1.25, apexX: apexX, apexY: apexY)
                    .fill(
                        LinearGradient(
                            colors: [
                                beamColor.opacity(0.32),
                                beamColor.opacity(0.16),
                                beamColor.opacity(0.05),
                                .clear
                            ],
                            startPoint: beamStart, endPoint: beamEnd
                        )
                    )
                    .blur(radius: 26)
                    .blendMode(.plusLighter)

                // Main beam body — the visible cone, gentle and even.
                beamPath(w: w, h: h, top: 18, bottom: bottomWidth, apexX: apexX, apexY: apexY)
                    .fill(
                        LinearGradient(
                            colors: [
                                beamColor.opacity(0.65),
                                beamColor.opacity(0.42),
                                beamColor.opacity(0.16),
                                .clear
                            ],
                            startPoint: beamStart, endPoint: beamEnd
                        )
                    )
                    .blur(radius: 9)
                    .blendMode(.plusLighter)

                // Inner core — slim, warmer near the source, dissolves long
                // before the page so no bright spot pools at the bottom.
                beamPath(w: w, h: h, top: 5, bottom: max(bottomWidth * 0.30, 60), apexX: apexX, apexY: apexY)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.65),
                                beamColor.opacity(0.45),
                                beamColor.opacity(0.10),
                                .clear
                            ],
                            startPoint: beamStart, endPoint: beamEnd
                        )
                    )
                    .blur(radius: 4)
                    .blendMode(.plusLighter)

                // Soft lamp at the icon — gentle glow centered ON the icon.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.75),
                                beamColor.opacity(0.50),
                                beamColor.opacity(0.12),
                                .clear
                            ],
                            center: .center, startRadius: 0, endRadius: 14
                        )
                    )
                    .frame(width: 28, height: 28)
                    .position(x: apexX, y: apexY)
                    .blendMode(.plusLighter)
            }
        }
    }

    /// Trapezoid widening from `top` (at apex point) to `bottom` (at y=h),
    /// centered horizontally on `apexX`.
    private func beamPath(w: CGFloat, h: CGFloat, top: CGFloat, bottom: CGFloat, apexX: CGFloat, apexY: CGFloat) -> Path {
        Path { p in
            p.move(to: CGPoint(x: apexX - top / 2, y: apexY))
            p.addLine(to: CGPoint(x: apexX + top / 2, y: apexY))
            p.addLine(to: CGPoint(x: apexX + bottom / 2, y: h))
            p.addLine(to: CGPoint(x: apexX - bottom / 2, y: h))
            p.closeSubpath()
        }
    }
}
