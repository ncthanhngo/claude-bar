import AppKit
import SwiftUI

/// Floating welcome window shown on first launch. Reuses the same
/// FloatingWindow level/lifetime semantics as the restore-flow sheets so it
/// survives the menu bar popover losing focus mid-flow (the user needs to
/// click Terminal during `claude /login`).
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    func present(
        store: AppStore,
        loginCoordinator: LoginCoordinator,
        settings: AppSettings,
        cloudSync: CloudSyncCoordinator
    ) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(
            rootView: OnboardingView(
                onFinish: { [weak self] in
                    settings.didCompleteOnboarding = true
                    self?.close()
                },
                onSkip: { [weak self] in
                    // Skip leaves didCompleteOnboarding false — the wizard
                    // returns on the next launch.
                    self?.close()
                }
            )
            .environmentObject(store)
            .environmentObject(loginCoordinator)
            .environmentObject(settings)
            .environmentObject(cloudSync)
        )

        let size = NSSize(width: 540, height: 620)
        // Pin the hosting controller so it doesn't auto-grow the window to
        // match the SwiftUI view's intrinsic size — OnboardingView uses
        // `.frame(maxHeight: .infinity)` which would otherwise expand the
        // window vertically without bound. `sizingOptions = []` disables
        // the intrinsic-content-size feedback loop; the SwiftUI view then
        // fills exactly whatever NSWindow content rect we provide.
        host.sizingOptions = []
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Welcome to Claude Bar"
        w.contentViewController = host
        w.setContentSize(size)
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
        window?.close()
        window = nil
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.window = nil }
    }
}
