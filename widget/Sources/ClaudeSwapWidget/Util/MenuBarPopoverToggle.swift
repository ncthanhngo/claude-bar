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

    /// Open the popover if it's currently hidden. No-op if already visible
    /// — important when the caller is a Picker `onChange` handler: clicking
    /// a segment in the standalone Settings window causes the popover to
    /// dismiss on focus loss, so the handler runs *after* the popover is
    /// already gone, and we need to bring it back without toggling.
    /// `performClick` would toggle a still-visible popover off, so we gate
    /// on the captured popover NSWindow's visibility (same source of truth
    /// `closeIfOpen` uses).
    static func openIfClosed() {
        let alreadyVisible = PopoverWindowRegistry.shared.window?.isVisible == true
        guard !alreadyVisible else { return }
        guard let button = findStatusBarButton() else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        button.performClick(nil)
    }

    /// Same as `openIfClosed` but lifts the popover window above any
    /// other app windows (Settings, Daily) that may otherwise cover it.
    /// Used by the Settings popover-layout Picker so each layout change
    /// re-opens the popover ON TOP of the Settings panel for preview,
    /// instead of behind it.
    ///
    /// Settings is pinned at `popUpMenu + 1` (see SettingsWindowController)
    /// so a normal popover at `.floating` (3) sits FAR below it. We boost
    /// the popover window's level to `popUpMenu + 2` for this preview
    /// flow only — z-order alone (`orderFrontRegardless`) is not enough
    /// when window levels differ. The level snaps back to `.floating`
    /// on the next normal menu-bar click because
    /// `PopoverWindowCapture.capture(from:)` enforces `.floating` every
    /// SwiftUI update cycle.
    static func openIfClosedAbove() {
        openIfClosed()
        // The popover window is captured asynchronously by
        // PopoverWindowCapture after `performClick`. Give it one runloop
        // tick to land in the registry, then lift.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard let w = PopoverWindowRegistry.shared.window else { return }
            let aboveSettings = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
            w.level = aboveSettings
            w.orderFrontRegardless()
        }
    }

    /// Dismiss the popover if it's currently shown. No-op if already closed.
    /// Used when opening another window (Daily) so the popover collapses back
    /// into the menu bar instead of overlapping the new window.
    ///
    /// Visibility is read from the captured popover NSWindow rather than the
    /// status-button `.state` — SwiftUI MenuBarExtra does not synchronize the
    /// button state with popover visibility, so KVO on `.state` returns stale
    /// values. Close via `performClick(nil)` (not `orderOut`) so SwiftUI's
    /// internal "popover is shown" flag stays consistent.
    static func closeIfOpen() {
        guard let w = PopoverWindowRegistry.shared.window, w.isVisible else { return }
        if let button = findStatusBarButton() {
            button.performClick(nil)
        } else {
            w.orderOut(nil)
        }
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

    /// Frame of the full status button (icon + trailing text) in screen coords.
    /// Returns nil when the button can't be located (very rare; fall back to a
    /// fixed pill).
    static func statusItemScreenFrame() -> NSRect? {
        guard let button = findStatusBarButton(), let win = button.window else {
            return nil
        }
        // Button.frame is in its window's coordinate space; convert to screen.
        let rectInWindow = button.convert(button.bounds, to: nil)
        return win.convertToScreen(rectInWindow)
    }

    /// Frame of just the icon graphic at the LEFT of the status button.
    /// MenuBarLabelView renders `HStack { icon, text }` so when text is shown
    /// (`compact` / `full` style) the full button frame extends well past the
    /// icon — anchoring visuals (e.g. Daily light beam) to `statusItemScreenFrame`
    /// puts them in the middle of the text instead of on the icon.
    ///
    /// First tries to locate the actual NSImageView SwiftUI bridges the icon
    /// to (most reliable). Falls back to a left-anchored rect sized from the
    /// rendered icon width.
    static func iconImageScreenFrame() -> NSRect? {
        guard let button = findStatusBarButton(), let win = button.window else {
            return nil
        }
        if let imageView = findLeftmostImageView(in: button) {
            let rectInWindow = imageView.convert(imageView.bounds, to: nil)
            return win.convertToScreen(rectInWindow)
        }
        // Fallback: SwiftUI MenuBarExtra lays the HStack flush against the
        // button's leading edge, so anchor at button.minX with no extra inset.
        let rectInWindow = button.convert(button.bounds, to: nil)
        let full = win.convertToScreen(rectInWindow)
        let iconW = renderedMenuBarIconWidth()
        let w = min(iconW, full.width)
        return NSRect(x: full.minX, y: full.minY, width: w, height: full.height)
    }

    /// Walk the button's subview tree for the leftmost image-like view —
    /// SwiftUI bridges `Image(nsImage:)` to an NSImageView (or a private class
    /// whose name contains "Image"). Returns the leftmost match so trailing
    /// text views don't win when both exist.
    private static func findLeftmostImageView(in root: NSView) -> NSView? {
        var best: NSView?
        func walk(_ v: NSView) {
            let cls = String(describing: type(of: v))
            if v !== root, cls.contains("Image"), v.bounds.width > 0, v.bounds.height > 0 {
                let frameInRoot = v.convert(v.bounds, to: root)
                if best == nil || frameInRoot.minX < best!.convert(best!.bounds, to: root).minX {
                    best = v
                }
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
        return best
    }

    /// Rendered width of the menu-bar icon image, mirroring MenuBarLabelView's
    /// scaling (height fixed at 16pt, width preserves aspect ratio).
    private static func renderedMenuBarIconWidth() -> CGFloat {
        guard let url = Bundle.main.url(forResource: "icon", withExtension: "png"),
              let src = NSImage(contentsOf: url), src.size.height > 0 else {
            return 16
        }
        let h: CGFloat = 16
        return round(h * src.size.width / src.size.height)
    }

    private static func firstStatusBarButton(in view: NSView) -> NSStatusBarButton? {
        if let b = view as? NSStatusBarButton { return b }
        for sub in view.subviews {
            if let b = firstStatusBarButton(in: sub) { return b }
        }
        return nil
    }
}
