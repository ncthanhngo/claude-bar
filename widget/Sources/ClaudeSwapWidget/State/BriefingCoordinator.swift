import Foundation
import Combine

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
        guard var b = briefing else { return }
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

    /// Toggle window visibility — used by the global hotkey (⌥X by default).
    func toggle() {
        if isWindowOpen { close() } else { show() }
    }

    // MARK: - Private helpers

    private func safeShow() async -> BriefingDTO? {
        try? await client.briefingShow()
    }
    private func safeScheduleGet() async -> BriefingScheduleDTO? {
        try? await client.briefingScheduleGet()
    }
}
