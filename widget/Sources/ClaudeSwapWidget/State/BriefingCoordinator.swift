import Foundation
import Combine
import AppKit

/// Bridges the SwiftUI views to the Go `csw briefing` subcommands.
/// Owns the polling loop that triggers `runNow()` when the scheduler says
/// today's briefing is due.
@MainActor
final class BriefingCoordinator: ObservableObject {
    @Published private(set) var briefing: BriefingDTO?
    @Published private(set) var schedule: BriefingScheduleDTO?
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published var isWindowOpen = false

    private let client: CswClient
    private var pollTask: Task<Void, Never>?
    private var keyWindowObserver: NSObjectProtocol?
    private var appDeactivateObserver: NSObjectProtocol?

    init(client: CswClient) { self.client = client }

    /// Start initial load + poll loop. Idempotent.
    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.loadInitial()
            while !Task.isCancelled {
                // Re-check every 5 minutes whether a run is due.
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                await self?.checkAndRunIfDue()
            }
        }
        Task { @MainActor [weak self] in
            await self?.attachPopoverObserver()
            self?.attachAppDeactivateObserver()
        }
    }

    /// Daily window and menu-bar popover are mutually exclusive: opening one
    /// dismisses the other. The "open Daily → close popover" half is handled
    /// by `MenuBarPopoverToggle.closeIfOpen()` in `BriefingWindowController`;
    /// this observer handles the reverse — close Daily when the popover
    /// specifically becomes key.
    ///
    /// Match the popover by identity against `PopoverWindowRegistry` instead of
    /// "any non-Daily window becomes key" — the broad check caused Daily to
    /// close on incidental focus shifts (SwiftUI sheets/popovers/menus inside
    /// Daily, NSAlert modals, NSOpenPanel) and on the brief intermediate key
    /// state during the popover-dismiss → Daily-makeKey handoff, which made
    /// in-Daily actions like "Đoạn chat mới" feel broken.
    /// Close Daily (and dismiss the menu-bar popover) the moment the user
    /// activates another app — Chrome, Xcode, anything outside Claude Bar.
    /// Without this, Daily lingers above the user's actual workspace until
    /// they explicitly hit X or ⌥X.
    ///
    /// `didResignActiveNotification` only fires when the entire app loses
    /// active status to ANOTHER app, so in-app focus shifts (SwiftUI sheets,
    /// NSAlert, file pickers) do not trigger it. That avoids the historical
    /// "Daily closes while typing in a TextField" footgun.
    private func attachAppDeactivateObserver() {
        if appDeactivateObserver != nil { return }
        appDeactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isWindowOpen { self.close() }
                MenuBarPopoverToggle.closeIfOpen()
            }
        }
    }

    private func attachPopoverObserver() async {
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            Task { @MainActor [weak self] in
                guard let self, self.isWindowOpen else { return }
                guard let popover = PopoverWindowRegistry.shared.window,
                      window === popover else { return }
                self.close()
            }
        }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    /// Pull today's cached briefing + schedule config without running Claude.
    func loadInitial() async {
        async let cached = safeShow()
        async let sched = safeScheduleGet()
        let (b, s) = await (cached, sched)
        if let b { self.briefing = b }
        if let s { self.schedule = s }
        await checkAndRunIfDue()
    }

    /// If scheduler says today's run is due, kick it off.
    func checkAndRunIfDue() async {
        guard !isRunning else { return }
        do {
            let check = try await client.briefingScheduleCheck()
            if check.shouldRun {
                await runNow()
            }
        } catch {
            self.lastError = CswError.redact(error.localizedDescription)
        }
    }

    /// Force a fresh run, ignoring the same-day cache.
    func runNow() async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        defer { isRunning = false }
        do {
            let b = try await client.briefingRun(force: true)
            self.briefing = b
        } catch {
            self.lastError = CswError.redact(error.localizedDescription)
        }
    }

    /// Persist done/undone state for one action; updates locally first.
    func toggleAction(id: String, done: Bool) async {
        guard let b = briefing else { return }
        if let idx = b.actions.firstIndex(where: { $0.id == id }) {
            // Optimistic update is not supported because ActionDTO is immutable
            // (struct with `let`). Re-fetch from backend instead.
            _ = idx
        }
        do {
            let updated = try await client.briefingToggleAction(date: b.date, id: id, done: done)
            self.briefing = updated
        } catch {
            self.lastError = CswError.redact(error.localizedDescription)
        }
    }

    func saveSchedule(cron: String, enabled: Bool) async {
        do {
            try await client.briefingScheduleSet(cron: cron, enabled: enabled)
            self.schedule = try? await client.briefingScheduleGet()
        } catch {
            self.lastError = CswError.redact(error.localizedDescription)
        }
    }

    /// Show the briefing window (animation handled by phase 07 view layer).
    func show() {
        isWindowOpen = true
        Task { await loadInitial() }
    }

    func close() { isWindowOpen = false }

    /// Three-state hotkey behaviour (⌥X by default):
    /// - Window not open → open it.
    /// - Window open but buried behind another app (not key) → pull it to the
    ///   front. The user just asked to see Daily; do not punish them by
    ///   closing it because the visibility flag happens to be `true`.
    /// - Window open AND already key (foreground) → close.
    func toggle() {
        if !isWindowOpen {
            show()
            return
        }
        if BriefingWindowController.shared.isKeyAndVisible {
            close()
        } else {
            BriefingWindowController.shared.bringToFront()
        }
    }

    // MARK: - Private helpers

    private func safeShow() async -> BriefingDTO? {
        try? await client.briefingShow()
    }
    private func safeScheduleGet() async -> BriefingScheduleDTO? {
        try? await client.briefingScheduleGet()
    }
}
