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
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = title
        w.contentViewController = host
        // Level above `popUpMenu` so if the popover is reopened while this
        // sheet is up (e.g. user clicks the menu-bar icon again), the sheet
        // still wins. statusBar+2 (= 27) was below popUpMenu (= 101) and
        // got covered.
        w.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
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
