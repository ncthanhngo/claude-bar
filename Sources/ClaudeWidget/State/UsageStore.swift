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

    // MARK: - Init

    private let scanQueue = DispatchQueue(label: "claude-widget.scan", qos: .utility)

    init() {
        self.config = ConfigStore.shared.load()
        self.accounts = AccountStore.loadAll()
        self.webConnected = WebUsageService.loadSessionKey() != nil
                         && WebUsageService.loadOrgId()      != nil
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
    /// `sessionKey` cookie so we can hit `claude.ai/api/.../usage`.
    func signInToClaudeAi() async throws {
        let sessionKey = try await LoginWindowController.runFlow()
        let orgId = try await WebUsageService.validateAndDetectOrg(sessionKey: sessionKey)
        WebUsageService.storeCredentials(sessionKey: sessionKey, orgId: orgId)
        webConnected = true
        webError = nil
        fetchWebUsage()
    }

    func disconnectClaudeAi() {
        WebUsageService.clearCredentials()
        webConnected = false
        webSnapshot = nil
        Task { await WebSessionClient.shared.clearSession() }
        rebuildSnapshot()
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
        // If this is the first account, mark it active.
        if config.activeAccountId == nil {
            config.activeAccountId = acc.id
            ConfigStore.shared.save(config)
        }
    }

    func switchToAccount(id: UUID) throws {
        _ = try AccountStore.switchTo(id: id)
        config.activeAccountId = id
        ConfigStore.shared.save(config)
        accounts = AccountStore.loadAll()
        rebuildSnapshot()
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

    // MARK: - Auto-switch

    private func evaluateAutoSwitch() {
        guard config.autoSwitchEnabled else { return }
        guard let candidate = AutoSwitcher.chooseCandidate(
            activeId: config.activeAccountId,
            accounts: accounts,
            currentPercent: snapshot.sessionPercent,
            threshold: config.autoSwitchThresholdPercent
        ) else { return }
        switch AutoSwitcher.performSwitch(to: candidate) {
        case .switched(let acc):
            config.activeAccountId = acc.id
            ConfigStore.shared.save(config)
            accounts = AccountStore.loadAll()
            rebuildSnapshot()
        case .failed(let msg):
            lastError = msg
        case .skipped:
            break
        }
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

    func setPlan(_ plan: Plan) {
        config.plan = plan
        ConfigStore.shared.save(config)
        rebuildSnapshot()
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
