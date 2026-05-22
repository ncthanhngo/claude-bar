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
    @Published private(set) var tokenStats: UsageStatsDTO?
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var swappingTo: Int?
    let client = CswClient()
    let settings = AppSettings.shared
    let autoSwap: AutoSwapStateMachine
    var cloudSync: CloudSyncCoordinator?
    var webUsageProvider: (([AccountViewDTO]) async -> [Int: UsageDTO])?

    private var refreshTask: Task<Void, Never>?

    init() {
        self.autoSwap = AutoSwapStateMachine(client: client, settings: AppSettings.shared)
        autoSwap.snapshotProvider = { [weak self] in self?.snapshot }
        autoSwap.sessionsProvider = { [weak self] in self?.sessions }
        autoSwap.onSwapPerformed = { [weak self] in
            await self?.refreshNow()
            self?.schedulePostSwapIntegrations()
            await self?.autoPushCloud()
        }
    }

    /// Begins the periodic refresh loop with adaptive interval:
    /// active 5h% < threshold -> low frequency; >= threshold -> high frequency.
    func start() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refreshNow()
            await self?.backupTokenRefreshIfNeeded()
            while !Task.isCancelled {
                guard let self else { return }
                let secs = self.nextRefreshIntervalSec()
                try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
                await self.backupTokenRefreshIfNeeded()
                await self.refreshNow()
            }
        }
        autoSwap.start()
    }

    private func backupTokenRefreshIfNeeded() async {
        let now = Date().timeIntervalSince1970
        let fullInterval: TimeInterval    = 6 * 60 * 60  // normal 6-hour cycle
        let transientRetry: TimeInterval  = 15 * 60      // retry window after transient failure

        let timeSinceAttempt  = now - settings.lastBackupTokenRefreshAt
        let timeSinceSuccess  = now - settings.lastBackupTokenRefreshSuccessAt
        // lastAttemptFailed: success timestamp is older than attempt timestamp
        // (with 60s margin so near-simultaneous writes don't false-positive).
        let lastAttemptFailed = timeSinceSuccess > timeSinceAttempt + 60

        let shouldAttempt = timeSinceAttempt >= fullInterval
                         || (lastAttemptFailed && timeSinceAttempt >= transientRetry)
        guard shouldAttempt else { return }

        settings.lastBackupTokenRefreshAt = now
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await client.refreshAllTokens()
            settings.lastBackupTokenRefreshSuccessAt = now
        } catch {
            print("[AppStore] Backup token refresh failed: \(error.localizedDescription)")
            // lastBackupTokenRefreshSuccessAt intentionally not updated on failure.
            // Next check after transientRetry will retry; persistent grant failures
            // are throttled by the fullInterval on the attempt timestamp.
        }
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
            async let sessionsAsync = client.sessions()
            async let tokenStatsAsync = client.usageStats()
            let metadata = try await client.list(includeUsage: false)
                .preservingUsageState(from: snapshot)
            let webUsages = await webUsageProvider?(metadata.accounts) ?? [:]
            // Include accounts where the web scraper returned only a partial
            // window (5h or 7d missing) — claude.ai often hydrates the weekly
            // block later than the 5h block, so without an OAuth top-up the
            // missing bar would never render until a subsequent poll happened
            // to catch a fully-hydrated scrape. `merging(over:)` below keeps
            // the web values where present and fills gaps from OAuth.
            let fallbackNumbers = metadata.accounts
                .map(\.id)
                .filter { id in
                    guard let usage = webUsages[id] else { return true }
                    return usage.fiveHour == nil || usage.sevenDay == nil
                }
            let fallback = fallbackNumbers.isEmpty
                ? metadata
                : try await client.list(usageAccounts: fallbackNumbers)
            let list = metadata
                .mergingUsageRows(fallback)
                .replacingUsage(webUsages)
            let sess = try await sessionsAsync
            self.snapshot = list
            self.sessions = sess
            // Token-stats failure is non-fatal — keep the last good value so
            // the UI doesn't blank out on a transient scan error.
            if let stats = try? await tokenStatsAsync {
                self.tokenStats = stats
            }
            self.lastError = nil
            self.lastRefreshAt = Date()
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    func swap(to num: Int) async {
        swappingTo = num
        do {
            print("[AppStore] Switching to account \(num)")
            try await client.switchTo(num)
            await refreshNow()
            print("[AppStore] Switched to account \(num)")
            swappingTo = nil
            schedulePostSwapIntegrations()
            await autoPushCloud()
        } catch {
            lastError = error.localizedDescription
            swappingTo = nil
            print("[AppStore] Switch failed: \(error.localizedDescription)")
        }
    }

    private func schedulePostSwapIntegrations() {
        Task { [weak self] in
            await self?.restartCLISessionsAfterSwap()
        }
        Task { [weak self] in
            await self?.reloadIDEsAfterSwap()
        }
    }

    private func restartCLISessionsAfterSwap() async {
        // Credentials must already be switched before SIGINT so claude-watch
        // can see the changed ~/.claude.json and restart the same terminal.
        var killCount = 0
        if settings.autoKillCLIAfterSwap {
            let killed = CLISessionKiller.killAll()
            killCount = killed.count
            if killCount > 0 {
                try? await Task.sleep(nanoseconds: 800_000_000) // 0.8s graceful
                CLISessionKiller.forceKillSurvivors(killed)
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s settle
            }
        }

        await postSwapNotification(
            killCount: killCount,
            reloaded: nil,
            autoKillEnabled: settings.autoKillCLIAfterSwap,
            autoReloadEnabled: false
        )
    }

    private func reloadIDEsAfterSwap() async {
        guard settings.autoReloadIDEAfterSwap else { return }
        let reloaded = await IDEReloader.reloadAll()
        await postSwapNotification(
            killCount: nil,
            reloaded: reloaded,
            autoKillEnabled: false,
            autoReloadEnabled: true
        )
    }

    private func postSwapNotification(killCount: Int?, reloaded: [String]?,
                                      autoKillEnabled: Bool, autoReloadEnabled: Bool) async {
        var lines: [String] = []
        if autoKillEnabled {
            let count = killCount ?? 0
            lines.append(count > 0 ? "Killed \(count) CLI session(s)" : "No CLI sessions to kill")
        }
        if autoReloadEnabled {
            let names = reloaded ?? []
            lines.append(names.isEmpty ? "IDE reload: no IDEs detected" : "Reloaded: \(names.joined(separator: ", "))")
        }
        guard !lines.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "Account switched"
        content.body = lines.joined(separator: "\n")
        let req = UNNotificationRequest(identifier: "csw.swap-done", content: content, trigger: nil)
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
        // Read passphrase on main actor first, then push in background.
        guard let cloud = cloudSync,
              let pass = cloud.loadPassphrase() else { return }
        Task.detached(priority: .background) { [weak cloud, pass] in
            await cloud?.push(passphrase: pass)
        }
    }
}
