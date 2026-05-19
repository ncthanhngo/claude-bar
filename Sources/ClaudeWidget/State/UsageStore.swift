import Foundation
import Combine

/// Single facade the UI binds to. Coordinates data sources
/// (`JsonlUsageService`, `WebUsageService`) and persistent stores
/// (`ConfigStore`, `AccountStore`).
///
/// All state-mutating work happens on the main actor; heavy IO is dispatched
/// to background queues / detached tasks and merged back on completion.
@MainActor
final class UsageStore: ObservableObject {

    // MARK: - Published UI state

    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var labelText: String = "··"

    @Published private(set) var jsonlBlocks: [SessionBlock] = []
    @Published private(set) var webSnapshot: WebUsageService.Snapshot?

    @Published private(set) var isScanning = false
    @Published private(set) var isFetchingWeb = false
    @Published private(set) var lastScannedAt: Date?

    @Published private(set) var webError: String?
    @Published var lastError: String?

    @Published var config: WidgetConfig
    @Published private(set) var accounts: [Account]
    @Published private(set) var webConnected: Bool
    @Published private(set) var pendingSwitch: PendingSwitch?

    // MARK: - Init

    private let scanQueue = DispatchQueue(label: "claude-widget.scan", qos: .utility)
    private var pendingPollTimer: Timer?
    private var multiAccountPollTimer: Timer?
    private var isPollingAccounts = false

    init() {
        self.config = ConfigStore.shared.load()
        self.accounts = AccountStore.loadAll()
        self.webConnected = WebUsageService.loadSessionKey() != nil
                         && WebUsageService.loadOrgId()      != nil
        configureMultiAccountPolling()
    }

    // MARK: - Derived

    var activeAccount: Account? {
        guard let id = config.activeAccountId else { return nil }
        return accounts.first(where: { $0.id == id })
    }
    var activeBlock: SessionBlock? {
        BlockCalculator.activeBlock(in: jsonlBlocks)
    }

    // MARK: - JSONL refresh

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        scanQueue.async { [weak self] in
            let records = JsonlUsageService.loadAllRecords()
            let blocks = BlockCalculator.computeBlocks(from: records)
            DispatchQueue.main.async {
                guard let self else { return }
                self.jsonlBlocks = blocks
                self.lastScannedAt = Date()
                self.isScanning = false
                self.rebuildSnapshot()
            }
        }
    }

    /// Lightweight UI refresh — recompute snapshot from already-cached data.
    func tick() { rebuildSnapshot() }

    // MARK: - Web (claude.ai/api) — ground truth

    func fetchWebUsage() {
        guard webConnected, !isFetchingWeb else { return }
        isFetchingWeb = true
        Task { [weak self] in await self?.runWebFetch() }
    }

    private func runWebFetch() async {
        defer { isFetchingWeb = false }
        do {
            let snap = try await WebUsageService.fetchSnapshot()
            webSnapshot = snap
            webError = nil
            if let active = activeAccount {
                AccountStore.recordObservation(
                    id: active.id,
                    percent: snap.sessionUtilization,
                    resetsAt: snap.sessionResetsAt
                )
                accounts = AccountStore.loadAll()
            }
            rebuildSnapshot()
            evaluateAutoSwitch()
        } catch {
            webError = error.localizedDescription
        }
    }

    // MARK: - Web auth (per-active-account web session)

    /// OAuth-style sign-in to the web (claude.ai) endpoint. Captures the
    /// `sessionKey` cookie so we can hit `claude.ai/api/.../usage`. Also
    /// persists the session into the active Account so the multi-account
    /// poller can use it without a re-sign-in.
    func signInToClaudeAi() async throws {
        let sessionKey = try await LoginWindowController.runFlow()
        let orgId = try await WebUsageService.validateAndDetectOrg(sessionKey: sessionKey)
        WebUsageService.storeCredentials(sessionKey: sessionKey, orgId: orgId)
        webConnected = true
        webError = nil

        if let activeId = config.activeAccountId,
           var acc = AccountStore.find(id: activeId) {
            acc.sessionKey = sessionKey
            acc.orgId = orgId
            try? AccountStore.update(acc)
            accounts = AccountStore.loadAll()
        }

        fetchWebUsage()
    }

    /// Sign into claude.ai and attach the captured session to a specific
    /// account row. Does **not** touch the global SecretStore — used by
    /// the per-row "Connect web" affordance so each saved account can be
    /// polled with its own cookie.
    func signInToClaudeAiForAccount(id: UUID) async throws {
        let sessionKey = try await LoginWindowController.runFlow()
        let orgId = try await WebUsageService.validateAndDetectOrg(sessionKey: sessionKey)
        guard var acc = AccountStore.find(id: id) else {
            throw AccountStore.AccountError.notFound
        }
        acc.sessionKey = sessionKey
        acc.orgId = orgId
        try AccountStore.update(acc)
        accounts = AccountStore.loadAll()
    }

    func disconnectClaudeAi() {
        WebUsageService.clearCredentials()
        webConnected = false
        webSnapshot = nil
        Task { await WebSessionClient.shared.clearSession() }
        rebuildSnapshot()
    }

    /// Clears the web session for a specific account row. If that row is
    /// the active one, also clears the global SecretStore so the main
    /// `fetchWebUsage` stops returning stale data.
    func disconnectWebForAccount(id: UUID) {
        guard var acc = AccountStore.find(id: id) else { return }
        acc.sessionKey = nil
        acc.orgId = nil
        acc.lastSessionPercent = nil
        acc.lastSessionResetsAt = nil
        try? AccountStore.update(acc)
        accounts = AccountStore.loadAll()
        if config.activeAccountId == id {
            disconnectClaudeAi()
        }
    }

    // MARK: - Accounts

    /// Snapshot Claude Code's current keychain credentials as a new account.
    func addCurrentClaudeCodeAccount(label: String) throws {
        let sessionKey = WebUsageService.loadSessionKey()
        let orgId = WebUsageService.loadOrgId()
        let acc = try AccountStore.addFromCurrentClaudeCode(
            label: label, sessionKey: sessionKey, orgId: orgId
        )
        accounts = AccountStore.loadAll()
        if config.activeAccountId == nil {
            config.activeAccountId = acc.id
            ConfigStore.shared.save(config)
            if let updated = AccountStore.find(id: acc.id) {
                applyAccountWebSession(updated)
            }
        }
    }

    /// Snapshot current Keychain creds with an explicit `sessionKey + orgId`
    /// override (used by the magic-link flow where we captured the cookie
    /// outside the global SecretStore). `email` is also persisted so future
    /// duplicate checks have a stable identifier even when the OAuth blob
    /// itself doesn't expose one.
    func addCurrentClaudeCodeAccount(label: String, sessionKey: String?, orgId: String?, email: String? = nil) throws {
        let acc = try AccountStore.addFromCurrentClaudeCode(
            label: label,
            sessionKey: sessionKey,
            orgId: orgId,
            email: email
        )
        accounts = AccountStore.loadAll()
        // First account auto-becomes active — also hydrate the global web
        // session from its captured cookie so HeroCard goes LIVE immediately
        // instead of falling back to JSONL estimation.
        if config.activeAccountId == nil {
            config.activeAccountId = acc.id
            ConfigStore.shared.save(config)
            if let updated = AccountStore.find(id: acc.id) {
                applyAccountWebSession(updated)
            }
        }
    }

    func switchToAccount(id: UUID) throws {
        let switched = try AccountStore.switchTo(id: id)
        config.activeAccountId = id
        ConfigStore.shared.save(config)
        accounts = AccountStore.loadAll()
        applyAccountWebSession(switched)
        rebuildSnapshot()
    }

    /// Copies the target account's saved `sessionKey + orgId` into the
    /// global `SecretStore.widget`. Keeps the main `fetchWebUsage` path in
    /// sync with whichever account just became active — otherwise the
    /// HeroCard % keeps showing the previous account's data until the next
    /// "Connect to claude.ai" or poll round.
    private func applyAccountWebSession(_ account: Account) {
        guard let key = account.sessionKey, !key.isEmpty,
              let org = account.orgId, !org.isEmpty else {
            // No per-account session saved — leave global cookie as-is.
            return
        }
        WebUsageService.storeCredentials(sessionKey: key, orgId: org)
        webConnected = true
        Task { await WebSessionClient.shared.setSessionKey(key) }
        fetchWebUsage()
    }

    func deleteAccount(id: UUID) {
        try? AccountStore.delete(id: id)
        accounts = AccountStore.loadAll()
        if config.activeAccountId == id {
            config.activeAccountId = nil
            ConfigStore.shared.save(config)
        }
    }

    func renameAccount(id: UUID, label: String) {
        guard var acc = AccountStore.find(id: id) else { return }
        acc.label = label
        try? AccountStore.update(acc)
        accounts = AccountStore.loadAll()
    }

    /// Checks Claude Code's current Keychain blob against saved accounts and
    /// returns the row that already represents this identity, if any. Used
    /// by the wizards to warn before snapshotting a duplicate.
    ///
    /// Three-stage match (most precise first):
    ///  1. **Byte-equal blob** — back-to-back snapshots of the same login.
    ///  2. **Identity key** — uuid / email-style fields in the blob match.
    ///  3. **Stripped signature** — same account metadata after removing
    ///     known ephemeral fields (access/refresh token, expiry, timestamps).
    ///     Catches the case where Claude Code refreshed tokens between the
    ///     two snapshots, even when neither blob has explicit identifier
    ///     keys we recognize.
    func findDuplicateForCurrentKeychain() -> Account? {
        guard let blob = try? ClaudeCodeCredentials.read(), !blob.isEmpty else {
            return nil
        }
        if let exact = accounts.first(where: { $0.oauthBlob == blob }) {
            return exact
        }
        if let id = OAuthBlobInspector.identifier(from: blob),
           let match = accounts.first(where: {
               OAuthBlobInspector.identifier(from: $0.oauthBlob) == id
           }) {
            return match
        }
        if let signature = OAuthBlobInspector.stableSignature(from: blob),
           let match = accounts.first(where: {
               OAuthBlobInspector.stableSignature(from: $0.oauthBlob) == signature
           }) {
            return match
        }
        return nil
    }

    /// Extends `findDuplicateForCurrentKeychain` with an email hint. Used by
    /// the magic-link flow: even if the Keychain blob's identity isn't
    /// recognizable (no `uuid`/`email` keys, fully token-only), the email
    /// decoded from the magic-link URL fragment can still match an already-
    /// saved row's `Account.email`.
    func findDuplicateForMagicLink(email: String?) -> Account? {
        if let blobMatch = findDuplicateForCurrentKeychain() {
            return blobMatch
        }
        guard let target = email?.lowercased(), !target.isEmpty else { return nil }
        return accounts.first { $0.email?.lowercased() == target }
    }

    // MARK: - Auto-switch

    private func evaluateAutoSwitch() {
        guard config.autoSwitchEnabled else {
            clearPendingSwitch()
            return
        }
        guard let candidate = AutoSwitcher.chooseCandidate(
            activeId: config.activeAccountId,
            accounts: accounts,
            currentPercent: snapshot.sessionPercent,
            threshold: config.autoSwitchThresholdPercent
        ) else {
            // Pct dropped below threshold or no candidate — cancel any pending.
            clearPendingSwitch()
            return
        }

        let runningPIDs = ClaudeProcessDetector.runningPIDs()
        if runningPIDs.isEmpty {
            commitSwitch(to: candidate)
        } else {
            defer { startPendingPollIfNeeded() }
            // Only notify when target changes — avoid spam on every refresh.
            let isNewTarget = pendingSwitch?.targetAccount.id != candidate.id
            pendingSwitch = PendingSwitch(
                targetAccount: candidate,
                blockingPIDs: runningPIDs,
                detectedAt: pendingSwitch?.detectedAt ?? Date()
            )
            if isNewTarget {
                AutoSwitcher.postPendingNotification(to: candidate, sessionCount: runningPIDs.count)
            }
        }
    }

    private func commitSwitch(to candidate: Account) {
        switch AutoSwitcher.performSwitch(to: candidate) {
        case .switched(let acc):
            config.activeAccountId = acc.id
            ConfigStore.shared.save(config)
            accounts = AccountStore.loadAll()
            applyAccountWebSession(acc)
            clearPendingSwitch()
            rebuildSnapshot()
        case .failed(let msg):
            lastError = msg
        case .skipped:
            break
        }
    }

    // MARK: - Pending switch polling

    /// Re-checks every 15s whether all blocking `claude` PIDs have exited.
    /// Started when `pendingSwitch` is set; stopped when it clears.
    private func startPendingPollIfNeeded() {
        guard pendingPollTimer == nil else { return }
        pendingPollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPendingSwitch() }
        }
    }

    private func pollPendingSwitch() {
        guard let pending = pendingSwitch else {
            clearPendingSwitch()
            return
        }
        let runningPIDs = ClaudeProcessDetector.runningPIDs()
        if runningPIDs.isEmpty {
            commitSwitch(to: pending.targetAccount)
        } else if runningPIDs != pending.blockingPIDs {
            // PIDs changed (some exited, some new spawned) — refresh UI counter.
            pendingSwitch = PendingSwitch(
                targetAccount: pending.targetAccount,
                blockingPIDs: runningPIDs,
                detectedAt: pending.detectedAt
            )
        }
    }

    func cancelPendingSwitch() {
        clearPendingSwitch()
    }

    private func clearPendingSwitch() {
        pendingSwitch = nil
        pendingPollTimer?.invalidate()
        pendingPollTimer = nil
    }

    // MARK: - Config

    func setAutoSwitchEnabled(_ enabled: Bool) {
        config.autoSwitchEnabled = enabled
        ConfigStore.shared.save(config)
        if enabled { AutoSwitcher.requestNotificationPermission() }
    }

    func setAutoSwitchThreshold(_ percent: Double) {
        config.autoSwitchThresholdPercent = min(99, max(50, percent))
        ConfigStore.shared.save(config)
    }

    func setMultiAccountPolling(enabled: Bool) {
        config.multiAccountPollingEnabled = enabled
        ConfigStore.shared.save(config)
        configureMultiAccountPolling()
    }

    func setMultiAccountPollInterval(seconds: Int) {
        config.multiAccountPollIntervalSeconds = max(30, seconds)
        ConfigStore.shared.save(config)
        configureMultiAccountPolling()
    }

    // MARK: - Multi-account polling

    private func configureMultiAccountPolling() {
        multiAccountPollTimer?.invalidate()
        multiAccountPollTimer = nil
        guard config.multiAccountPollingEnabled else { return }
        let interval = TimeInterval(config.multiAccountPollIntervalSeconds)
        // Fire one round immediately so user sees data after enabling.
        Task { await pollAllAccounts() }
        multiAccountPollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.pollAllAccounts() }
            }
        }
    }

    private func pollAllAccounts() async {
        guard !isPollingAccounts else { return }
        guard accounts.contains(where: { ($0.sessionKey?.isEmpty == false) && ($0.orgId?.isEmpty == false) && $0.id != config.activeAccountId }) else { return }
        isPollingAccounts = true
        defer { isPollingAccounts = false }
        let refreshed = await MultiAccountPoller.runRound(
            accounts: accounts,
            activeId: config.activeAccountId
        )
        accounts = refreshed
    }

    // MARK: - Snapshot derivation

    private func rebuildSnapshot() {
        snapshot = UsageSnapshotBuilder.build(
            web: webSnapshot,
            jsonlBlock: activeBlock,
            fallbackLimit: config.effectiveLimit
        )
        labelText = MenuBarLabel.format(snapshot)
    }
}
