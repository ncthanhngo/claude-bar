import AppKit
import SwiftUI

/// Owns the dedicated News NSWindow, opened globally via ⌥X
/// (`BriefingHotkeySlot.openBriefing`). Mirrors `SettingsWindowController`
/// exactly: `.normal` level (a standard app panel, not a floating overlay),
/// resizable, singleton so re-triggering ⌥X brings the existing window
/// forward instead of stacking duplicates.
@MainActor
final class NewsWindowController: NSObject, NSWindowDelegate {
    static let shared = NewsWindowController()

    private var window: NSWindow?
    private var cursorTracker: SettingsCursorTracker?
    /// Same injection pattern as `SettingsWindowController.bindEnvironment` —
    /// the News window lives outside the MenuBarExtra view tree, so the
    /// coordinators it needs (currently just app identity; more as Phase 3/4
    /// wire in SSH relay status etc.) are captured in a closure bound once
    /// from `ClaudeSwapWidgetApp`'s coordinator wiring.
    private var environmentBuilder: ((AnyView) -> AnyView)?
    private let store = NewsStore()

    func bindEnvironment(_ builder: @escaping (AnyView) -> AnyView) {
        self.environmentBuilder = builder
    }

    /// Open the News window, or bring it forward + kick a refresh if already
    /// open. Opening always triggers a `refresh()` — the "on-open" cadence
    /// from the plan's architecture decisions.
    func show() {
        if let existing = window {
            existing.level = .normal
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            store.beginAutoRefresh()
            Task { await store.refresh() }
            return
        }

        let size = NSSize(width: 1180, height: 780)
        let host = NSHostingController(rootView: hostedRoot())
        // Pin size — without this, intrinsic-content sizing can collapse the
        // window while the feed is still loading and renders no content.
        host.sizingOptions = []

        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "\(AppInfo.displayName) News"
        w.contentViewController = host
        w.setContentSize(size)
        w.minSize = NSSize(width: 760, height: 540)
        w.level = .normal
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        cursorTracker = SettingsCursorTracker.install(on: w)

        store.beginAutoRefresh()
        Task { await store.refresh() }
    }

    /// Programmatic close. The user-driven path (red X / ⌘W) lands in
    /// `windowWillClose`.
    func close() {
        window?.close()
        window = nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        store.endAutoRefresh()
        cursorTracker?.uninstall()
        cursorTracker = nil
        window = nil
    }

    // MARK: - Content

    private func hostedRoot() -> AnyView {
        let content = NewsDashboardView().environmentObject(store)
        if let env = environmentBuilder {
            return env(AnyView(content))
        }
        return AnyView(content)
    }
}
