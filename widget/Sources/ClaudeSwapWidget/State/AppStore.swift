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
    /// Typed surface for the most recent failed swap. Cleared on dismiss /
    /// successful retry. Drives `SwapErrorOverlay` so the menu header stays
    /// usable for steady-state status while the modal owns swap diagnostics.
    @Published var swapError: SwapError?
    let client = CswClient()
    let settings = AppSettings.shared
    let autoSwap: AutoSwapStateMachine
    var cloudSync: CloudSyncCoordinator?
    /// Reachable by Phases 3/4/5 via the state machine and by any future view
    /// that needs to inspect per-account recovery status or trigger recovery.
    /// Set once at app launch by the wiring in `ClaudeSwapWidgetApp`.
    weak var recovery: CredentialRecoveryCoordinator?
    var webUsageProvider: (([AccountViewDTO]) async -> [Int: UsageDTO])?
    /// Synchronous "is this account web-linked?" query so refreshNow can
    /// route around the OAuth usage fallback for already-linked accounts.
    /// Set once by WebFallbackCoordinator.attach; nil during tests / launch
    /// boot, in which case refreshNow falls back to the legacy behaviour
    /// (probe OAuth whenever web data is missing).
    var isWebLinked: ((AccountDTO) -> Bool)?

    /// Last time `refreshNow` actually issued an OAuth usage fallback list
    /// call. Used to gate Anthropic's rate-limited `/usage` endpoint to its
    /// own cadence (`refreshIntervalSec` / `refreshIntervalHighSec`) while
    /// the outer loop polls web-scraped accounts every 60/30s. Nil before
    /// the first call so the very first refresh always hits OAuth.
    private var lastOAuthFallbackAt: Date?

    /// Web-scrape cadence floor (active 5h < threshold). Hardcoded — the
    /// scrape goes through the user's own claude.ai cookie session via
    /// WKWebView, not Anthropic's OAuth `/usage` endpoint, so it doesn't
    /// share the 429 budget. v11.9 set this to 60s but multi-account users
    /// reported the popover hanging: each scrape costs 3–8s (hidden
    /// WKWebView reload + React SPA hydrate) plus a keychain/iCloud cookie
    /// restore+save, so at 60s × N accounts the main actor saturates and
    /// UI updates stall. 120s leaves headroom for 2–3 web-linked accounts
    /// while still being ~33% faster than the OAuth default (180s).
    private static let webRefreshIntervalSec = 120
    /// Web-scrape cadence ceiling (active 5h ≥ adaptiveHighThresholdPct).
    /// Halved from `webRefreshIntervalSec`. Same backoff reasoning as
    /// above — 30s was too tight for multi-account web scrapes.
    private static let webRefreshIntervalHighSec = 60

    private var refreshTask: Task<Void, Never>?

    init() {
        self.autoSwap = AutoSwapStateMachine(client: client, settings: AppSettings.shared)
        autoSwap.snapshotProvider = { [weak self] in self?.snapshot }
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

        // Sync indicator state is only meaningful when iCloud is actually
        // configured (passphrase saved). Without a passphrase, autoPull /
        // autoPush silently no-op and we'd otherwise mislabel a refresh-only
        // cycle as a "successful sync".
        let cloudPassphrase = cloudSync?.loadPassphrase()
        var cycleError: String = ""
        if cloudPassphrase != nil {
            settings.lastAutoSyncAt = now
        }

        // Pull first so we refresh against the freshest cross-device tokens.
        // Anthropic rotates refresh tokens on every use — if device A rotated
        // an inactive account's RT overnight and pushed to iCloud, B's locally
        // cached RT is already invalid. Pulling closes that race before our
        // own refresh tries the stale RT and trips invalid_grant.
        if let cloud = cloudSync, let pass = cloudPassphrase {
            let res = await cloud.pullQuiet(passphrase: pass)
            if case .failed(let msg) = res {
                cycleError = "pull: \(msg)"
            }
        }

        var refreshOk = false
        do {
            try await client.refreshAllTokens()
            settings.lastBackupTokenRefreshSuccessAt = now
            refreshOk = true
        } catch {
            print("[AppStore] Backup token refresh failed: \(error.localizedDescription)")
            // lastBackupTokenRefreshSuccessAt intentionally not updated on failure.
            // Next check after transientRetry will retry; persistent grant failures
            // are throttled by the fullInterval on the attempt timestamp.
            if cycleError.isEmpty {
                cycleError = "refresh: \(error.localizedDescription)"
            }
        }

        // Push so other devices pick up our newly-rotated tokens before their
        // next refresh cycle (mirrors the pull above on the peer). Run even
        // if refresh failed — pushing the current local state is still
        // useful for any account that didn't fail (`needsRelogin` doesn't
        // block push at the backend level).
        if let cloud = cloudSync, let pass = cloudPassphrase {
            let pushRes: CloudSyncCoordinator.QuietResult = await withCheckedContinuation { cont in
                Task.detached(priority: .background) { [weak cloud, pass] in
                    let r = await cloud?.pushQuiet(passphrase: pass) ?? .failed("coordinator gone")
                    cont.resume(returning: r)
                }
            }
            if case .failed(let msg) = pushRes, cycleError.isEmpty {
                cycleError = "push: \(msg)"
            }

            // Final outcome for the Diagnostics chip. Half-failures (refresh
            // ok but push failed) deliberately do NOT bump success — the
            // local rotation isn't published yet, so the peer is at risk.
            if refreshOk && cycleError.isEmpty {
                settings.lastAutoSyncSuccessAt = now
                settings.lastAutoSyncError = ""
            } else {
                settings.lastAutoSyncError = cycleError
            }
        }
    }

    /// Computes the next sleep duration based on the most recent active 5h%.
    /// Falls back to the low interval when no usage is available yet.
    ///
    /// When any account is web-linked, drops to the web-scrape cadence
    /// (60s / 30s) instead of the OAuth cadence (180s / 120s by default).
    /// The OAuth `/usage` call inside `refreshNow` is still gated by
    /// `lastOAuthFallbackAt` so Anthropic's rate-limited endpoint keeps
    /// its own slower cadence even on the faster outer loop.
    func nextRefreshIntervalSec() -> Int {
        let cutoff = settings.adaptiveHighThresholdPct
        let pct = snapshot?.active?.usage?.fiveHour?.percentInt
        let isHigh = (pct ?? 0) >= cutoff
        if anyAccountWebLinked() {
            return isHigh ? Self.webRefreshIntervalHighSec : Self.webRefreshIntervalSec
        }
        let low = max(30, settings.refreshIntervalSec)
        let high = max(30, settings.refreshIntervalHighSec)
        return isHigh ? high : low
    }

    /// OAuth `/usage` cadence — kept at the user-configurable 180s / 120s
    /// defaults regardless of the outer loop's web-driven cadence. Used by
    /// `refreshNow` to skip the OAuth fallback call on web-poll cycles.
    private func nextOAuthIntervalSec() -> Int {
        let low = max(30, settings.refreshIntervalSec)
        let high = max(30, settings.refreshIntervalHighSec)
        let cutoff = settings.adaptiveHighThresholdPct
        let pct = snapshot?.active?.usage?.fiveHour?.percentInt
        if let pct, pct >= cutoff { return high }
        return low
    }

    private func anyAccountWebLinked() -> Bool {
        guard let check = isWebLinked, let accs = snapshot?.accounts else { return false }
        return accs.contains { check($0.account) }
    }

    func stop() {
        refreshTask?.cancel()
        autoSwap.stop()
    }

    func refreshNow() async {
        // Coalesce overlapping callers — manual "Refresh web usage"
        // clicks, the timer-driven loop, post-swap re-refresh, and the
        // initial-launch refresh can all race. Without this guard a
        // hung WKWebView scrape from one call holds the main actor while
        // the next call piles another scrape on top — minutes later we
        // get a flood of 40–50s CancellationErrors and the popover
        // cannot render. Drop the new call when one's already in flight.
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let sessionsAsync = client.sessions()
            async let tokenStatsAsync = client.usageStats()
            let metadata = try await client.list(includeUsage: false)
                .preservingUsageState(from: snapshot)
            let webUsages = await webUsageProvider?(metadata.accounts) ?? [:]
            // Per-account rule: web is the source of truth whenever it returns
            // anything for that account. OAuth (the "terminal" path) only
            // kicks in when web returned **nothing at all** — i.e. the
            // account isn't linked, or its WebView session expired and
            // delivered an empty result this cycle.
            //
            // Partial web data (only 5h, only 7d) is treated as "web worked"
            // — the next poll re-hydrates the missing window from claude.ai
            // without dragging OAuth into the loop every refresh.
            //
            // For accounts that are NOT web-linked: legacy partial-fill
            // behaviour stays (OAuth top-up when a 5h-only scrape exists),
            // because those accounts have no future web hydration to wait
            // for.
            let linkedCheck = isWebLinked
            // Gate OAuth fallback to its own cadence so the faster web-poll
            // outer loop (60/30s) doesn't burn Anthropic's rate-limited
            // `/usage` budget. First refresh always runs OAuth so terminal
            // accounts hydrate immediately on launch.
            let oauthDue: Bool = {
                guard let last = lastOAuthFallbackAt else { return true }
                let interval = Double(nextOAuthIntervalSec())
                return Date().timeIntervalSince(last) >= interval
            }()
            let fallbackNumbers: [Int] = oauthDue
                ? metadata.accounts
                    .filter { view in
                        let usage = webUsages[view.id]
                        if linkedCheck?(view.account) == true {
                            // Web-linked: probe OAuth only when web returned no
                            // usage object at all this cycle.
                            return usage == nil
                        }
                        // Not web-linked: probe OAuth when web missing OR partial.
                        guard let usage else { return true }
                        return usage.fiveHour == nil || usage.sevenDay == nil
                    }
                    .map(\.id)
                : []
            // Isolate the OAuth fallback in its own do/catch so a transient
            // 429 / expired-creds on a terminal account doesn't blow away
            // the entire refresh cycle (including web-linked accounts that
            // already returned fresh data). Pre-fix: a throw here aborted
            // the outer `do`, snapshot stayed stale, popover hung on
            // "Loading…" for everyone — that's what users see when Dev 2 /
            // Dev 3 OAuth fails while Thanh's web scrape succeeds.
            let fallback: ListAccountsDTO
            if fallbackNumbers.isEmpty {
                fallback = metadata
            } else {
                do {
                    fallback = try await client.list(usageAccounts: fallbackNumbers)
                    lastOAuthFallbackAt = Date()
                } catch {
                    DiagnosticsLogger.shared.log(.warning, subsystem: "oauth-usage",
                        "fallback failed for \(fallbackNumbers) — \(error.localizedDescription)")
                    fallback = metadata
                    // Still bump the timestamp so we don't hammer the
                    // failing endpoint every cycle; the next OAuth-due
                    // window will retry naturally.
                    lastOAuthFallbackAt = Date()
                }
            }
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
        swapError = nil
        do {
            print("[AppStore] Switching to account \(num)")
            try await client.switchTo(num)
            await refreshNow()
            print("[AppStore] Switched to account \(num)")
            swappingTo = nil
            schedulePostSwapIntegrations()
            await autoPushCloud()
        } catch {
            let detail = error.localizedDescription
            print("[AppStore] Switch failed: \(detail)")
            swappingTo = nil
            let name = snapshot?.accounts.first(where: { $0.account.number == num })?.account.displayName
                ?? "tài khoản #\(num)"
            swapError = SwapError(targetAccount: num, targetName: name, message: detail)
            // Keep lastError nil for swap failures: the header status line is
            // for steady-state polling errors, not user-actionable swap modals.
            lastError = nil
        }
    }

    /// Re-attempt the swap that produced `swapError`. Clears the error first
    /// so the overlay doesn't flicker between the failure and the next outcome.
    func retryFailedSwap() async {
        guard let err = swapError, err.allowsRetry else { return }
        let num = err.targetAccount
        swapError = nil
        await swap(to: num)
    }

    /// Dismiss the swap error overlay without retrying.
    func dismissSwapError() {
        swapError = nil
    }

    /// Fires the SIGINT-then-`claude-watch --resume`, IDE reload, and cmux
    /// pane relaunch pipeline. Called from the swap path and from
    /// [[QuickReloginCoordinator]] when an active account's tokens have just
    /// been rewritten — semantically the same situation as a swap to the
    /// "same account, fresh credentials", so it reuses the same toggles
    /// (`autoKillCLIAfterSwap`, `autoReloadIDEAfterSwap`) and the always-on
    /// cmux relauncher.
    func schedulePostSwapIntegrations() {
        Task { [weak self] in
            await self?.restartCLISessionsAfterSwap()
        }
        Task { [weak self] in
            await self?.reloadIDEsAfterSwap()
        }
        Task { [weak self] in
            await self?.relaunchCmuxClaudePanesAfterSwap()
        }
    }

    private func restartCLISessionsAfterSwap() async {
        // Credentials must already be switched before SIGINT so claude-watch
        // can see the changed ~/.claude.json and restart the same terminal.
        // When cmux pane relaunch is enabled, those PIDs are skipped here so
        // the dedicated relauncher can run `claude --resume <sid>` cleanly.
        var killCount = 0
        if settings.autoKillCLIAfterSwap {
            // Always skip cmux-tracked PIDs — the dedicated cmux pane
            // relauncher restarts them with `claude --resume <sid>` so the
            // conversation continues. A SIGINT here would race the resume.
            let killed = CLISessionKiller.killAll(skipCmuxTracked: true)
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

    private func relaunchCmuxClaudePanesAfterSwap() async {
        // Always runs. When no cmux panes are active the relauncher returns
        // an empty list and this is a no-op — no notification, no side effects.
        let outcomes = await CmuxPaneRelauncher.relaunchAll()
        guard !outcomes.isEmpty else { return }

        let resumed = outcomes.filter { $0.succeeded }.count
        let skippedIsolated = outcomes.filter { $0.skipped == .isolatedConfigDir }.count
        let cmuxMissing = outcomes.contains { $0.skipped == .cmuxNotInstalled }

        var lines: [String] = []
        if resumed > 0 { lines.append("Resumed \(resumed) cmux pane(s)") }
        if skippedIsolated > 0 { lines.append("Skipped \(skippedIsolated) isolated cmux pane(s)") }
        if cmuxMissing { lines.append("`cmux` not on PATH — install or add to PATH") }
        guard !lines.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = "Cmux relaunch"
        content.body = lines.joined(separator: "\n")
        let req = UNNotificationRequest(identifier: "csw.cmux-relaunch", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
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
        // pushQuiet swallows errors so background sync failures (iCloud not
        // mounted yet, transient network) don't pollute the diagnostics panel
        // — manual Push still surfaces errors via the regular `push` entry.
        guard let cloud = cloudSync,
              let pass = cloud.loadPassphrase() else { return }
        Task.detached(priority: .background) { [weak cloud, pass] in
            await cloud?.pushQuiet(passphrase: pass)
        }
    }

    /// Pulls the iCloud bundle synchronously before our own refresh-tokens
    /// cycle runs, so we never refresh against a refresh-token that another
    /// device has already rotated. Silent on failure (no UI error surface).
    /// Not detached — the caller relies on the pull completing first.
    private func autoPullCloud() async {
        guard let cloud = cloudSync,
              let pass = cloud.loadPassphrase() else { return }
        await cloud.pullQuiet(passphrase: pass)
    }
}
