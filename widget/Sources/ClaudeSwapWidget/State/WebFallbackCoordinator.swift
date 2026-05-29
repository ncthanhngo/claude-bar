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

    private let window = FloatingWindow<AnyView>()

    func attach(store: AppStore) {
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
    }

    func state(for account: AccountDTO) -> WebUsageAccountState {
        accountStates[account.identityKey] ?? (profileID(for: account) == nil ? .notLinked : .linked)
    }

    func isLinked(_ account: AccountDTO) -> Bool {
        profileID(for: account) != nil
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
            // Hard 12s ceiling so a hung WKWebView load (DNS stall,
            // claude.ai redirect loop, login race) can't block the
            // entire refresh cycle. Without this we observed 40–50s
            // pending tasks piling up on the main actor.
            let fetcher = ClaudeWebUsageFetcher(dataStore: dataStore)
            let usage = try await withThrowingTaskGroup(of: UsageDTO.self) { group in
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
            DiagnosticsLogger.shared.log(.info, subsystem: "web-usage",
                "ok \(view.account.email) (\(elapsedMs)ms) — \(usage.diagnosticSummary)")
            return usage
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            accountStates[view.account.identityKey] = .fallback(error.localizedDescription)
            lastCheckedAt = Date()
            DiagnosticsLogger.shared.log(.warning, subsystem: "web-usage",
                "fail \(view.account.email) (\(elapsedMs)ms) — \(error.localizedDescription)")
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
