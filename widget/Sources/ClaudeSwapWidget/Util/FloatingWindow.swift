import AppKit
import SwiftUI

/// A reusable floating panel that hosts a SwiftUI view above the menu bar dropdown.
///
/// Use this for sheets that must survive the MenuBarExtra losing focus
/// (e.g. the Add-account wizard, where the user has to click Terminal mid-flow).
///
/// `onClose` lets callers sync back any @State boolean that drives presentation
/// when the user dismisses via the window's red close button — without it, the
/// binding stays at true and the next "open" no-ops.
@MainActor
final class FloatingWindow<Content: View>: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    /// Fires when the user closes the window via its title-bar close button.
    /// Suppressed when `close()` is called programmatically.
    var onClose: (() -> Void)?

    func show(title: String, size: NSSize, @ViewBuilder content: () -> Content) {
        // Do NOT dismiss the menu-bar popover here. The bindings passed into
        // `content()` point at @State on a SwiftUI view hosted INSIDE the
        // popover (DiagnosticsTab) — when the popover collapses, that view
        // tears down and @State resets, leaving the sheet's text field bound
        // to dead state ("Save" stays disabled because the parent's @State
        // for passphraseField is back to "" even after the user types).
        //
        // Instead, raise the floating window above the popover's level
        // (popUpMenu = 101) so the sheet sits on top WITHOUT collapsing
        // the popover that owns the bindings.
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: content())
        // Disable NSHostingController's intrinsic-content-size feedback so
        // it doesn't auto-resize the window to match the SwiftUI view's
        // preferred dimensions. Without this, a view using
        // `.frame(maxHeight: .infinity)` grows the window unbounded, and a
        // view that's empty during async-data loading shrinks it. We always
        // want the explicitly-passed `size`.
        host.sizingOptions = []
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = title
        w.contentViewController = host
        // Pin content area to the requested size; combined with `sizingOptions = []`
        // above, the SwiftUI view fills whatever space the window gives it.
        w.setContentSize(size)
        // Level: above Settings window (popUpMenu+1) so sheets triggered
        // from inside Settings sit on top of Settings, not behind it. Also
        // beats the menu-bar popover (popUpMenu) so re-opening the menu
        // bar can't cover an in-flight sheet.
        w.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.delegate = self
        // Center on the Settings window when it's the current host, instead
        // of screen-center — keeps the sheet visually tethered to the
        // button the user just clicked.
        if let host = settingsHostWindow() {
            let hFrame = host.frame
            w.setFrameOrigin(NSPoint(
                x: hFrame.midX - size.width / 2,
                y: hFrame.midY - size.height / 2
            ))
        } else {
            w.center()
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    /// Returns the Settings window if it's currently visible — used by
    /// `show()` to center child sheets on it rather than the screen.
    private func settingsHostWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "Claude Bar Settings" && $0.isVisible }
    }

    func close() {
        // Clear callback BEFORE close() so windowWillClose doesn't re-notify the
        // caller — programmatic close already implies the caller is in sync.
        onClose = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        let cb = onClose
        onClose = nil
        window = nil
        cb?()
    }
}
