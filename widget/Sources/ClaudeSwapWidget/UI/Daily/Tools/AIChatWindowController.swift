import AppKit
import SwiftUI

/// Hosts the AI advisor chat in its OWN movable NSWindow (not a sheet), so the
/// user can drag it anywhere and it survives switching to another app. While
/// it's open, `BriefingCoordinator` skips its "close Daily on app deactivate"
/// behaviour so both stay put. Floating level keeps the chat visible above the
/// app you switch to — a reference panel you consult while working elsewhere.
@MainActor
final class AIChatWindowController: NSObject, NSWindowDelegate {
    static let shared = AIChatWindowController()

    private var window: NSWindow?
    var isOpen: Bool { window != nil }

    /// Open (or refocus + re-seed) the chat window with a tool's context. Each
    /// call starts a fresh chat by swapping in a new hosting controller, so the
    /// advisor picks up the new system/context instead of the stale guard.
    func present(palette: BriefingPalette, title: String, system: String,
                 context: String, suggestions: [String]) {
        let root = AIChatView(palette: palette, system: system, context: context, suggestions: suggestions)
        if let w = window {
            w.contentViewController = NSHostingController(rootView: root)
            w.title = title
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: root))
        w.title = title
        w.styleMask = [.titled, .closable, .resizable]
        w.minSize = NSSize(width: 360, height: 420)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.isMovableByWindowBackground = true
        w.delegate = self
        dockBesideDaily(w)
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Place the chat as a side panel to the RIGHT of the Daily window, matching
    /// its height. Falls back to the left of Daily when the right is off-screen,
    /// and to a centered default if Daily isn't open. Only runs on first open —
    /// once the user drags the window we leave it where they put it.
    private func dockBesideDaily(_ w: NSWindow) {
        let width: CGFloat = 430
        guard let daily = BriefingWindowController.shared.windowFrame,
              let screen = NSScreen.main else {
            w.setContentSize(NSSize(width: width, height: 580)); w.center(); return
        }
        let vis = screen.visibleFrame
        let gap: CGFloat = 12
        let height = min(daily.height, vis.height - 8)
        var x = daily.maxX + gap
        if x + width > vis.maxX { x = daily.minX - gap - width }   // no room right → dock left
        x = max(vis.minX + 4, min(x, vis.maxX - width - 4))
        let y = max(vis.minY + 4, min(daily.minY, vis.maxY - height - 4))
        w.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}
