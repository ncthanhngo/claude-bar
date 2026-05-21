import AppKit
import SwiftUI

/// A reusable floating panel that hosts a SwiftUI view above the menu bar dropdown.
///
/// Use this for sheets that must survive the MenuBarExtra losing focus
/// (e.g. the Add-account wizard, where the user has to click Terminal mid-flow).
@MainActor
final class FloatingWindow<Content: View> {
    private var window: NSWindow?

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
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func close() {
        window?.close()
        window = nil
    }
}
