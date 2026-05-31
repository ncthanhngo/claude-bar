import AppKit
import Foundation
import SwiftUI
import WebKit

enum WebUsageAccountState {
    case notLinked
    case linked
    case connected(String)
    case fallback(String)

    var label: String {
        switch self {
        case .notLinked: return "Terminal fallback"
        case .linked: return "Web linked"
        case .connected(let summary): return "Web connected: \(summary)"
        case .fallback: return "Web unavailable"
        }
    }

    var detail: String? {
        if case .fallback(let message) = self { return message }
        return nil
    }
}

@MainActor
final class WebFallbackCoordinator: ObservableObject {
    @AppStorage("webUsageProfileIdentifiersJSON")
    private var profileIdentifiersJSON: String = "{}"

    @Published private(set) var accountStates: [String: WebUsageAccountState] = [:]
    @Published private(set) var lastCheckedAt: Date?
    /// Last time the keep-alive loop completed a tick. Nil until the first
    /// tick fires (3–5h after app start). Surfaced by the Diagnostics tab.
    @Published private(set) var keepAliveLastTickAt: Date?
    /// Number of accounts pinged in the most recent tick (0 when every
    /// linked account was already fresh). Surfaced by the Diagnostics tab
    /// so the user can tell a tick that ran-but-did-nothing apart from
    /// "loop hasn't fired yet".
    @Published private(set) var keepAliveLastPingedCount: Int = 0

    private let window = FloatingWindow<AnyView>()

    /// Per-account timestamp of the most recent successful web scrape.
    /// Drives the keep-alive loop so we know which linked accounts have
    /// gone quiet long enough to risk session-cookie idle timeout. Lives
    /// only in memory — on app restart the polling loop fills it in within
    /// the first cycle, so persistence isn't worth the AppStorage cost.
    private var lastWebSuccessAt: [String: Date] = [:]
    /// Weak reference back into the store so the keep-alive loop can
    /// resolve current AccountViewDTOs from the live snapshot. Set in
    /// `attach(store:)`; nil before that or after the store is torn down
    /// (tests), in which case keep-alive simply skips its tick.
    private weak var store: AppStore?
    private var keepAliveTask: Task<Void, Never>?
    /// Account is "due for keep-alive" once its last successful scrape is
    /// older than this. 20h leaves comfortable headroom below the typical
    /// 24–48h session-cookie idle window claude.ai uses without making
    /// us ping every account every day even when polling already covered it.
    private static let keepAliveThreshold: TimeInterval = 20 * 60 * 60
    /// Wake the keep-alive checker every 3–6h (jittered). At 4 web-linked
    /// accounts × 1 ping a piece, that's at most ~16 extra requests/day —
    /// barely a blip compared with the normal poll loop, and only happens
    /// for accounts that genuinely went quiet.
    private static let keepAliveBaseInterval: TimeInterval = 4 * 60 * 60
    private static let keepAliveJitter: TimeInterval = 1 * 60 * 60

    /// Per-account rate-limit backoff. When claude.ai returns 429 / 403 on
    /// the usage navigation we park that account until `Date()` passes the
    /// stored deadline so the polling loop stops hammering the same blocked
    /// response. Step durations grow exponentially: 5m → 15m → 1h, then
    /// stays capped at 1h until a successful fetch clears the slot.
    struct BackoffState: Equatable {
        var until: Date
        var step: Int   // 0 = first hit (5m), 1 = 15m, 2+ = 1h
    }
    /// `@Published` so SwiftUI views (the account row badge) re-render
    /// when a 429 lands or when a successful poll clears the slot.
    /// Stale entries (`until` already in the past) are pruned lazily on
    /// read by `rateLimitedUntil` so we don't need a separate timer.
    @Published private(set) var backoff: [String: BackoffState] = [:]
    private static let backoffSteps: [TimeInterval] = [
        5 * 60,    // 5 min
        15 * 60,   // 15 min
        60 * 60    // 1 h (cap)
    ]

    func attach(store: AppStore) {
        self.store = store
        store.webUsageProvider = { [weak self] accounts in
            await self?.fetchWebUsages(for: accounts) ?? [:]
        }
        // Lets AppStore.refreshNow route around the OAuth usage fallback for
        // accounts the user has already linked via the Safari WebView. Stays
        // synchronous so the check happens inline during the refresh loop
        // without an extra await hop.
        store.isWebLinked = { [weak self] account in
            self?.isLinked(account) ?? false
        }
        startKeepAliveLoop()
    }

    /// Kicks off the background loop that pings quiet web-linked accounts.
    /// Cancels any previous loop first so re-attaching (tests, future
    /// reload scenarios) doesn't leak parallel tickers.
    private func startKeepAliveLoop() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Jittered sleep — uniform spread over a 2h window around
                // the base. Avoids producing a perfect daily heartbeat
                // pattern in claude.ai's logs.
                let jitter = Double.random(in: -Self.keepAliveJitter...Self.keepAliveJitter)
                let secs = Self.keepAliveBaseInterval + jitter
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                if Task.isCancelled { return }
                await self.runKeepAlive()
            }
        }
    }

    /// One pass of the keep-alive checker. For each web-linked account
    /// quiet for longer than `keepAliveThreshold` (and not currently in
    /// rate-limit backoff), trigger a normal `refreshWebUsage`. Reusing
    /// the standard path means cookie save / cloud push / backoff handling
    /// all run identically — keep-alive is purely about WHEN we poll, not
    /// HOW.
    private func runKeepAlive() async {
        // Always stamp the tick time so the Diagnostics row distinguishes
        // "loop is alive but skipped (disabled / no accounts)" from "loop
        // never fired". Pinged count below reflects actual work done.
        keepAliveLastTickAt = Date()
        guard AppSettings.shared.cookieKeepAliveEnabled,
              let store,
              let accounts = store.snapshot?.accounts else {
            keepAliveLastPingedCount = 0
            return
        }
        let now = Date()
        var pinged = 0
        for view in accounts {
            let key = view.account.identityKey
            guard isLinked(view.account) else { continue }
            // Backoff trumps keep-alive: we deliberately gave this account
            // a rest because claude.ai pushed back. Pinging during that
            // window defeats the purpose.
            if let until = backoff[key]?.until, until > now { continue }
            let last = lastWebSuccessAt[key]
            let quietFor = last.map { now.timeIntervalSince($0) } ?? .infinity
            guard quietFor >= Self.keepAliveThreshold else { continue }
            DiagnosticsLogger.shared.log(.info, subsystem: "keep-alive",
                "pinging \(view.account.email) (quiet \(Int(quietFor / 3600))h)")
            _ = await refreshWebUsage(for: view)
            pinged += 1
        }
        keepAliveLastPingedCount = pinged
    }

    func state(for account: AccountDTO) -> WebUsageAccountState {
        accountStates[account.identityKey] ?? (profileID(for: account) == nil ? .notLinked : .linked)
    }

    func isLinked(_ account: AccountDTO) -> Bool {
        profileID(for: account) != nil
    }

    /// Returns the future `Date` at which this account exits its backoff
    /// window, or `nil` if it isn't currently rate-limited. UI consumers
    /// use this for the row-level badge.
    func rateLimitedUntil(_ account: AccountDTO) -> Date? {
        guard let state = backoff[account.identityKey], state.until > Date() else {
            return nil
        }
        return state.until
    }

    func open(for view: AccountViewDTO) {
        guard let dataStore = linkedDataStore(for: view.account, createIfNeeded: true) else {
            accountStates[view.account.identityKey] = .fallback("Unable to create web usage profile.")
            return
        }
        window.show(
            title: "Web Usage - \(view.account.displayName)",
            size: NSSize(width: 720, height: 640)
        ) {
            AnyView(
                WebFallbackSheet(accountView: view, dataStore: dataStore)
                    .environmentObject(self)
            )
        }
        accountStates[view.account.identityKey] = .linked
    }

    func refreshWebUsage(for view: AccountViewDTO) async -> UsageDTO? {
        // Backoff gate — skip the scrape entirely while the account is
        // parked. We surface the wait time in the state label so the
        // popover can show "rate-limited, retrying in Xm" instead of a
        // generic error every cycle.
        if let state = backoff[view.account.identityKey], state.until > Date() {
            let secs = Int(state.until.timeIntervalSinceNow)
            accountStates[view.account.identityKey] =
                .fallback("Rate-limited by claude.ai — retrying in ~\(max(1, secs / 60))m")
            return nil
        }
        guard let dataStore = linkedDataStore(for: view.account, createIfNeeded: false) else {
            accountStates[view.account.identityKey] = .notLinked
            return nil
        }
        _ = await ClaudeWebSessionSync.restore(account: view.account, dataStore: dataStore)
        // Save cookies BEFORE the fetch — they represent the linked session
        // and should be persisted (locally + cloud bundle) even if the usage
        // endpoint returns a transient 404 / rate-limit. Gating save on fetch
        // success previously meant a single bad poll on app launch could leave
        // the cloud bundle empty for the entire poll cycle.
        await ClaudeWebSessionSync.save(account: view.account, dataStore: dataStore)
        let started = Date()
        do {
            // Fast path: direct JSON API call (~3 KB per request) using the
            // claude.ai session cookies already in the WKWebsiteDataStore.
            // Falls through to the legacy WebView scrape if the API returns
            // a non-2xx (Cloudflare challenge, expired session, schema
            // drift) so we keep working even when Anthropic moves the
            // endpoint around.
            let usage: UsageDTO
            var apiAttempted = false
            var apiResult: UsageDTO?
            if let orgUuid = view.account.organizationUuid, !orgUuid.isEmpty {
                apiAttempted = true
                do {
                    apiResult = try await ClaudeWebUsageAPI.fetch(orgUuid: orgUuid, dataStore: dataStore)
                } catch {
                    DiagnosticsLogger.shared.log(.warning, subsystem: "usage-api",
                        "fast path FAILED \(view.account.email) — \(error.localizedDescription)")
                }
            }
            if let direct = apiResult {
                usage = direct
                DiagnosticsLogger.shared.log(.info, subsystem: "usage-api",
                    "fast path \(view.account.email) — \(direct.diagnosticSummary)")
            } else {
                if apiAttempted {
                    DiagnosticsLogger.shared.log(.info, subsystem: "usage-api",
                        "falling back to WebView scrape for \(view.account.email)")
                }
                // Hard 12s ceiling so a hung WKWebView load (DNS stall,
                // claude.ai redirect loop, login race) can't block the
                // entire refresh cycle. Without this we observed 40–50s
                // pending tasks piling up on the main actor.
                let fetcher = ClaudeWebUsageFetcher(dataStore: dataStore)
                usage = try await withThrowingTaskGroup(of: UsageDTO.self) { group in
                    group.addTask { try await fetcher.fetchUsage() }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 12_000_000_000)
                        throw ClaudeWebUsageError.usagePageNotReady
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next() else {
                        throw ClaudeWebUsageError.usagePageNotReady
                    }
                    return first
                }
            }
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            // If any scraped window's resetsAt is already in the past the SPA
            // re-rendered a pre-reset cached state. Drop the result so the
            // OAuth fallback can fetch the new window — otherwise the widget
            // keeps replacing fresh data with the same stale scrape forever.
            if usage.hasPastResetWindow {
                accountStates[view.account.identityKey] = .fallback("Web profile returned stale usage (post-reset)")
                lastCheckedAt = Date()
                DiagnosticsLogger.shared.log(.warning, subsystem: "web-usage",
                    "stale post-reset \(view.account.email) (\(elapsedMs)ms) — \(usage.diagnosticSummary)")
                return nil
            }
            accountStates[view.account.identityKey] = .connected(usage.diagnosticSummary)
            lastCheckedAt = Date()
            // Record success for the keep-alive loop so it knows this
            // account doesn't need an explicit ping for another ~20h.
            lastWebSuccessAt[view.account.identityKey] = Date()
            // Successful scrape clears any pending backoff — the account is
            // healthy again so the next 429 starts fresh at step 0 (5 min).
            backoff.removeValue(forKey: view.account.identityKey)
            DiagnosticsLogger.shared.log(.info, subsystem: "web-usage",
                "ok \(view.account.email) (\(elapsedMs)ms) — \(usage.diagnosticSummary)")
            return usage
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            // Apply exponential backoff for explicit rate-limit / forbidden
            // responses. Other errors (load timeout, parse fail, etc.) keep
            // the previous behaviour — they re-try on the next poll because
            // they're usually transient and not driven by our request rate.
            if case ClaudeWebUsageError.rateLimited(let status) = error {
                let nextStep = (backoff[view.account.identityKey]?.step ?? -1) + 1
                let capped = min(nextStep, Self.backoffSteps.count - 1)
                let wait = Self.backoffSteps[capped]
                backoff[view.account.identityKey] = BackoffState(
                    until: Date().addingTimeInterval(wait),
                    step: capped
                )
                accountStates[view.account.identityKey] =
                    .fallback("Rate-limited (HTTP \(status)) — backing off \(Int(wait / 60))m")
                DiagnosticsLogger.shared.log(.warning, subsystem: "web-usage",
                    "rate-limit \(view.account.email) (\(elapsedMs)ms) HTTP=\(status) step=\(capped) wait=\(Int(wait))s")
            } else {
                accountStates[view.account.identityKey] = .fallback(error.localizedDescription)
                DiagnosticsLogger.shared.log(.warning, subsystem: "web-usage",
                    "fail \(view.account.email) (\(elapsedMs)ms) — \(error.localizedDescription)")
            }
            lastCheckedAt = Date()
            return nil
        }
    }

    func disconnect(_ account: AccountDTO) async {
        if let dataStore = linkedDataStore(for: account, createIfNeeded: false) {
            await ClaudeWebSession.clear(dataStore: dataStore)
        }
        var identifiers = loadProfileIdentifiers()
        identifiers.removeValue(forKey: account.identityKey)
        saveProfileIdentifiers(identifiers)
        ClaudeWebSessionSync.remove(account: account)
        accountStates[account.identityKey] = .notLinked
    }

    func refreshConnectionState(for account: AccountDTO, dataStore: WKWebsiteDataStore) async {
        let connected = await ClaudeWebSession.isConnected(dataStore: dataStore)
        if !connected {
            accountStates[account.identityKey] = .fallback("Sign in to this Claude web profile.")
        } else if case .connected = accountStates[account.identityKey] {
            await ClaudeWebSessionSync.save(account: account, dataStore: dataStore)
            return
        } else {
            await ClaudeWebSessionSync.save(account: account, dataStore: dataStore)
            accountStates[account.identityKey] = .linked
        }
    }

    func dismiss() {
        window.close()
    }

    private func fetchWebUsages(for accounts: [AccountViewDTO]) async -> [Int: UsageDTO] {
        var usages: [Int: UsageDTO] = [:]
        for account in accounts {
            await restoreSyncedProfile(for: account.account)
            guard isLinked(account.account) else { continue }
            if let usage = await refreshWebUsage(for: account) {
                usages[account.id] = usage
            }
        }
        return usages
    }

    /// Public wrapper so the Quick-relogin flow can reuse the same per-account
    /// WKWebsiteDataStore the web-usage scraper already manages. Reusing the
    /// store means a user who linked their claude.ai web profile gets a single
    /// Authorize click during OAuth re-login instead of being asked to log in
    /// twice. See [[QuickReloginCoordinator]].
    func linkedDataStorePublic(for account: AccountDTO, createIfNeeded: Bool) -> WKWebsiteDataStore? {
        linkedDataStore(for: account, createIfNeeded: createIfNeeded)
    }

    private func linkedDataStore(for account: AccountDTO, createIfNeeded: Bool) -> WKWebsiteDataStore? {
        var identifiers = loadProfileIdentifiers()
        let rawID: String
        if let existing = identifiers[account.identityKey] {
            rawID = existing
        } else if createIfNeeded {
            rawID = UUID().uuidString
            identifiers[account.identityKey] = rawID
            saveProfileIdentifiers(identifiers)
        } else {
            return nil
        }
        guard let id = UUID(uuidString: rawID) else { return nil }
        return WKWebsiteDataStore(forIdentifier: id)
    }

    private func restoreSyncedProfile(for account: AccountDTO) async {
        guard profileID(for: account) == nil,
              ClaudeWebSessionSync.hasSession(for: account),
              let dataStore = linkedDataStore(for: account, createIfNeeded: true) else {
            return
        }
        if await ClaudeWebSessionSync.restore(account: account, dataStore: dataStore) {
            accountStates[account.identityKey] = .linked
        }
    }

    private func profileID(for account: AccountDTO) -> UUID? {
        guard let rawID = loadProfileIdentifiers()[account.identityKey] else { return nil }
        return UUID(uuidString: rawID)
    }

    private func loadProfileIdentifiers() -> [String: String] {
        guard let data = profileIdentifiersJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveProfileIdentifiers(_ identifiers: [String: String]) {
        guard let data = try? JSONEncoder().encode(identifiers),
              let json = String(data: data, encoding: .utf8) else { return }
        profileIdentifiersJSON = json
    }
}

private extension UsageDTO {
    var diagnosticSummary: String {
        let fiveHour = fiveHour.map { "5h \($0.percentInt)%" } ?? "5h unavailable"
        let sevenDay = sevenDay.map { "7d \($0.percentInt)%" } ?? "7d unavailable"
        return "\(fiveHour), \(sevenDay)"
    }
}
