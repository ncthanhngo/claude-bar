import AppKit

/// macOS `MenuBarExtra` doesn't expose its NSStatusItem via public API, so we
/// reach the underlying NSStatusBarButton by walking the app's windows and
/// looking for it inside the content-view subtree. `performClick(nil)` on the
/// button toggles the popover the same way a manual click would.
@MainActor
enum MenuBarPopoverToggle {
    /// Programmatically click the status bar item, opening the menu bar
    /// popover if it's closed and closing it if it's already open.
    static func toggle() {
        guard let button = findStatusBarButton() else {
            // Fall back to activating the app so at least the user sees focus.
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        button.performClick(nil)
    }

    /// Walk NSApp.windows looking for an NSStatusBarButton anywhere in the
    /// content view subtree.
    static func findStatusBarButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            if let v = window.contentView, let btn = firstStatusBarButton(in: v) {
                return btn
            }
        }
        return nil
    }

    /// Frame of the menu-bar icon in screen coordinates. Returns nil when the
    /// button can't be located (very rare; fall back to a fixed pill).
    static func statusItemScreenFrame() -> NSRect? {
        guard let button = findStatusBarButton(), let win = button.window else {
            return nil
        }
        // Button.frame is in its window's coordinate space; convert to screen.
        let rectInWindow = button.convert(button.bounds, to: nil)
        return win.convertToScreen(rectInWindow)
    }

    private static func firstStatusBarButton(in view: NSView) -> NSStatusBarButton? {
        if let b = view as? NSStatusBarButton { return b }
        for sub in view.subviews {
            if let b = firstStatusBarButton(in: sub) { return b }
        }
        return nil
    }
}
