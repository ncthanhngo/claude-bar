import Foundation
import SwiftUI
import UserNotifications

/// Top-level observable state for the menu UI.
///
/// Owns the polling timer for usage refresh and exposes async actions for
/// the views (switch, add, rename, remove).
@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var snapshot: ListAccountsDTO?
    @Published private(set) var sessions: SessionReportDTO?
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var swappingTo: Int?
    @Published var pendingBusySwap: PendingBusySwap?

    struct PendingBusySwap: Identifiable {
        let id = UUID()
        let targetNumber: Int
        let targetName: String
        let sessions: [RunningSession]
    }

    let client = CswClient()
    let settings = AppSettings.shared
    let autoSwap: AutoSwapStateMachine
    var cloudSync: CloudSyncCoordinator?

    private var refreshTask: Task<Void, Never>?

    init() {
        self.autoSwap = AutoSwapStateMachine(client: client, settings: AppSettings.shared)
        autoSwap.snapshotProvider = { [weak self] in self?.snapshot }
        autoSwap.sessionsProvider = { [weak self] in self?.sessions }
        autoSwap.onSwapPerformed = { [weak self] in
            await self?.refreshNow()
        }
    }

    /// Begins the periodic refresh loop with adaptive interval:
    /// active 5h% < threshold -> low frequency; >= threshold -> high frequency.
    func start() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refreshNow()
            // Daily token refresh — runs once per calendar day on startup.
            await self?.dailyTokenRefreshIfNeeded()
            while !Task.isCancelled {
                guard let self else { return }
                let secs = self.nextRefreshIntervalSec()
                try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
                await self.refreshNow()
            }
        }
        autoSwap.start()
    }

    private func dailyTokenRefreshIfNeeded() async {
        let today = todayString()
        guard settings.lastDailyTokenRefreshDay != today else { return }
        do {
            try await client.refreshAllTokens()
            settings.lastDailyTokenRefreshDay = today
        } catch {
            // Non-fatal: log and skip — will retry next launch
            print("[AppStore] Daily token refresh failed: \(error.localizedDescription)")
        }
    }

    private func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Computes the next sleep duration based on the most recent active 5h%.
    /// Falls back to the low interval when no usage is available yet.
    func nextRefreshIntervalSec() -> Int {
        let low = max(30, settings.refreshIntervalSec)
        let high = max(30, settings.refreshIntervalHighSec)
        let cutoff = settings.adaptiveHighThresholdPct
        let pct = snapshot?.active?.usage?.fiveHour?.percentInt
        if let pct, pct >= cutoff { return high }
        return low
    }

    func stop() {
        refreshTask?.cancel()
        autoSwap.stop()
    }

    func refreshNow() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let listAsync = client.list()
            async let sessionsAsync = client.sessions()
            let (list, sess) = try await (listAsync, sessionsAsync)
            self.snapshot = list
            self.sessions = sess
            self.lastError = nil
            self.lastRefreshAt = Date()
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    func swap(to num: Int) async {
        swappingTo = num
        defer { swappingTo = nil }
        do {
            try await client.switchTo(num)
            if settings.autoKillCLIAfterSwap {
                CLISessionKiller.killAll()
            }
            await refreshNow()
            if settings.autoReloadIDEAfterSwap {
                let reloaded = await IDEReloader.reloadAll()
                if !reloaded.isEmpty {
                    await postIDEReloadNotification(reloaded)
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func postIDEReloadNotification(_ names: [String]) async {
        let joined = names.joined(separator: ", ")
        let content = UNMutableNotificationContent()
        content.title = "Reloaded \(joined)"
        content.body = "Claude extension restarting with new account."
        let req = UNNotificationRequest(identifier: "csw.ide-reload", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    func addAccount(nickname: String?) async -> AddAccountDTO? {
        do {
            let res = try await client.add(nickname: nickname)
            await refreshNow()
            await autoPushCloud()
            return res
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func rename(_ num: Int, to nickname: String) async {
        do {
            try await client.rename(num, to: nickname)
            await refreshNow()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func remove(_ num: Int) async {
        do {
            try await client.remove(num)
            await refreshNow()
            await autoPushCloud()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Cloud sync helpers

    private func autoPushCloud() async {
        guard let cloud = cloudSync,
              let pass = cloud.loadPassphrase() else { return }
        await cloud.push(passphrase: pass)
    }
}
