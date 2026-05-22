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
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: content())
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = title
        w.contentViewController = host
        // Use a level above the Settings window, which is elevated to statusBar+1
        // when opened from the menu bar. .floating (3) would be covered by it.
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
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
