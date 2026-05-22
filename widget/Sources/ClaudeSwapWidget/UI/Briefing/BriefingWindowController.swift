import AppKit
import SwiftUI
import Combine

/// Owns the borderless NSWindow that hosts BriefingView and animates it open
/// "expanding from the menu bar" → center of screen.
///
/// macOS does not expose the MenuBarExtra status item frame via public API.
/// We approximate by starting the window as a thin pill in the top-right
/// corner (where most users' menu-bar icons live) and expanding to a near-
/// fullscreen frame with a spring curve.
@MainActor
final class BriefingWindowController: NSObject, NSWindowDelegate {
    static let shared = BriefingWindowController()

    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?
    private var coordinatorObserver: AnyCancellable?
    private weak var coordinator: BriefingCoordinator?

    // MARK: - Public API

    /// Attach to a coordinator's `isWindowOpen` flag — opening / closing the
    /// window is driven from the @Published binding, so any caller (hotkey,
    /// menu link, Telegram callback) just flips `coord.show()` / `close()`.
    func attach(coordinator: BriefingCoordinator) {
        self.coordinator = coordinator
        coordinatorObserver = coordinator.$isWindowOpen.sink { [weak self] open in
            guard let self else { return }
            Task { @MainActor in
                if open { self.present(with: coordinator) }
                else    { self.dismiss() }
            }
        }
    }

    // MARK: - Window plumbing

    private func present(with coordinator: BriefingCoordinator) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let view = BriefingView()
            .environmentObject(coordinator)
        let host = NSHostingController(rootView: AnyView(view))
        self.hostingController = host

        let w = makeWindow()
        w.contentViewController = host
        w.delegate = self
        self.window = w

        animateOpen(window: w)
    }

    private func dismiss() {
        guard let w = window else { return }
        animateClose(window: w) { [weak self] in
            self?.window = nil
            self?.hostingController = nil
        }
    }

    // MARK: - Frames

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: startFrame,
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.hasShadow = true
        w.backgroundColor = .clear
        w.isOpaque = false
        // Soft rounded chrome — NSVisualEffectView would clip our SwiftUI bg;
        // keep the SwiftUI background and just round the window corners.
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.cornerRadius = 22
        w.contentView?.layer?.masksToBounds = true
        return w
    }

    /// Small pill near the top-right corner — approximates menu-bar icon area.
    private var startFrame: NSRect {
        guard let screen = NSScreen.main else { return NSRect(x: 0, y: 0, width: 240, height: 56) }
        let v = screen.visibleFrame
        let w: CGFloat = 240, h: CGFloat = 56
        // 24px below the menu bar, 220px from the right edge of the visible frame.
        let x = v.maxX - w - 220
        let y = v.maxY - h - 8
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// Near-fullscreen, centered, with 32px inset on each side.
    private var endFrame: NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 100, y: 100, width: 1400, height: 900)
        }
        let v = screen.visibleFrame
        let inset: CGFloat = 32
        return v.insetBy(dx: inset, dy: inset)
    }

    // MARK: - Animation

    private func animateOpen(window w: NSWindow) {
        w.setFrame(startFrame, display: false)
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Use NSAnimationContext for smooth resize + fade-in.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.55
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1.0) // easeOutExpo-ish
            ctx.allowsImplicitAnimation = true
            w.animator().setFrame(endFrame, display: true, animate: true)
            w.animator().alphaValue = 1.0
        })
    }

    private func animateClose(window w: NSWindow, completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.30
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.7, 0.2) // easeInQuint-ish
            ctx.allowsImplicitAnimation = true
            w.animator().setFrame(startFrame, display: true, animate: true)
            w.animator().alphaValue = 0
        }, completionHandler: {
            w.orderOut(nil)
            completion()
        })
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        coordinator?.close()
        return false // we drive close via the coordinator binding
    }
}
