import AppKit
import SwiftUI

/// Owns the dedicated Settings NSWindow. The window:
///   • opens centered on the main screen,
///   • survives the menu-bar popover collapsing (it sits above popUpMenu
///     level, same trick FloatingWindow uses for connect sheets),
///   • only closes when the user explicitly closes it (red title-bar
///     button, ⌘W, or Quit). Clicking outside or losing focus does NOT
///     dismiss it — that's the contract this controller exists to enforce.
///
/// Singleton because Settings is a single canonical surface app-wide;
/// re-opening just brings the existing window forward instead of stacking.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var cursorTracker: SettingsCursorTracker?
    /// Environment dependencies are injected when the popover first wires
    /// the controller, so the SwiftUI content has the same coordinators
    /// the in-popover SettingsTab used to receive automatically.
    private var environmentBuilder: ((AnyView) -> AnyView)?

    /// Bind the environment objects once (from `ClaudeSwapWidgetApp.body
    /// .task`). The closure captures whatever @EnvironmentObjects the
    /// settings subtree needs so the Settings window — which lives outside
    /// the MenuBarExtra view tree — can still read them.
    func bindEnvironment(_ builder: @escaping (AnyView) -> AnyView) {
        self.environmentBuilder = builder
    }

    /// Open Settings, or bring it forward if already open.
    func show() {
        if let existing = window {
            // Belt-and-suspenders: an earlier build pinned this window at
            // `popUpMenu + 1` so it floated above Chrome / other apps; if
            // a user's existing window object came from that build (state
            // restoration, hot-reload) it keeps the old level until we
            // explicitly reset it here. Forces `.normal` so the window
            // behaves like a standard app panel — coverable by Chrome
            // when Chrome activates.
            existing.level = .normal
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let size = NSSize(width: 980, height: 660)
        let host = NSHostingController(rootView: hostedRoot())
        // Pin size — without this, intrinsic-content sizing collapses the
        // window when the active tab momentarily renders no content.
        host.sizingOptions = []

        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Claude Bar Settings"
        w.contentViewController = host
        w.setContentSize(size)
        w.minSize = NSSize(width: 820, height: 540)
        // Normal window level so other apps (Chrome, terminals, etc.) can
        // cover Settings by activating their own front window — Settings
        // should behave like any standard app panel, not a floating
        // overlay. The menu-bar popover sits at `.floating` so it
        // naturally overlaps Settings when both are visible together;
        // `MenuBarPopoverToggle.openIfClosedAbove` boosts the popover
        // further if needed for the layout-preview flow.
        w.level = .normal
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        // Single-point pointing-hand cursor manager — no need to decorate
        // every Button / Toggle in every tab.
        cursorTracker = SettingsCursorTracker.install(on: w)
    }

    /// Programmatic close. The user-driven path (red X / ⌘W) lands in
    /// `windowWillClose`.
    func close() {
        window?.close()
        window = nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Tear down the cursor monitor first so it stops firing for
        // mouse moves once the window is gone.
        cursorTracker?.uninstall()
        cursorTracker = nil
        // Clear the reference so a subsequent show() builds a fresh
        // window instead of trying to re-front the closed instance.
        window = nil
    }

    // MARK: - Content

    private func hostedRoot() -> AnyView {
        let content = SettingsTab()
        if let env = environmentBuilder {
            return env(AnyView(content))
        }
        return AnyView(content)
    }
}
