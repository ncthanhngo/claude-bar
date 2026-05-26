import AppKit
import SwiftUI

struct DiagnosticsTab: View {
    /// Settings IA splits this surface across two sidebar entries —
    /// `iCloud Sync` (sync toggle + bundle file share) and `Diagnostics`
    /// (the operational read-mostly stuff). One struct still owns all the
    /// state and sheet plumbing because both modes share the same iCloud
    /// passphrase prompts and restore preview windows when the iCloud
    /// surface launches them; rendering is just gated on `mode` so each
    /// tab shows only the groups it owns.
    enum Mode { case iCloud, diagnostics }

    var mode: Mode = .diagnostics

    @EnvironmentObject var store: AppStore
    @EnvironmentObject var verifyCoordinator: VerifyCoordinator
    @EnvironmentObject var webFallback: WebFallbackCoordinator
    @EnvironmentObject var cloudSync: CloudSyncCoordinator

    // Mirrors AppSettings.lastAutoSync* via the same UserDefaults keys so the
    // iCloud group's sync chip refreshes whenever a background cycle writes
    // a new timestamp — without needing AppStore to publish a change.
    @AppStorage("lastAutoSyncAt") private var lastAutoSyncAt: Double = 0
    @AppStorage("lastAutoSyncSuccessAt") private var lastAutoSyncSuccessAt: Double = 0
    @AppStorage("lastAutoSyncError") private var lastAutoSyncError: String = ""

    // Master toggle. When false the app never reads the Keychain passphrase
    // item, so a freshly-signed Sparkle build skips the macOS ACL prompt on
    // first launch after each update.
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = false

    @State private var showRestoreBackupSheet = false
    @State private var restoreBackupPassphrase = ""
    @State private var restoreSelectedSlot: Int?
    @State private var restoreConfirmSlot: Int?
    @State private var showRestorePreviewSheet = false
    @State private var restorePreviewSlot: Int = 0
    @State private var restorePreviewPassphrase: String = ""
    @State private var restorePreviewSelection: Set<String> = []
    // Non-nil = preview sheet is reviewing an imported bundle file (cross-
    // Apple-ID share), nil = reviewing an iCloud bundle slot. The sheet uses
    // this to pick between cloudPullSelective and cloudImportSelective.
    @State private var restorePreviewImportPath: String? = nil

    // SwiftUI .sheet() attaches to the popover window, which dismisses on
    // focus loss — every click inside the sheet collapses the menu bar
    // popover and orphans the flow. Host these sheets in standalone NSWindow
    // instances instead so the restore wizard survives losing menu bar focus.
    // The passphrase prompt uses NSAlert (CloudPassphrasePrompt) instead so
    // its single text field returns synchronously without depending on
    // popover-hosted @State surviving the modal.
    @State private var backupWindow = FloatingWindow<AnyView>()
    @State private var previewWindow = FloatingWindow<AnyView>()

    // Force-refresh local state (moved here from the popover header).
    @State private var isForceRefreshing = false
    @State private var forceRefreshOutcome: ForceRefreshOutcome? = nil
    @State private var forceRefreshCooldownActive = false
    private static let forceRefreshCooldownSec: Int = 10

    /// Renders the groups belonging to `mode`. Each mode is a top-level
    /// Settings tab now (iCloud Sync vs. Diagnostics) so this view brings
    /// its own scroll surface and `SettingsPage` padding — no outer
    /// wrapper expected from a parent.
    var body: some View {
        ScrollView {
            SettingsPage {
                switch mode {
                case .iCloud:
                    iCloudGroup
                    bundleFileGroup
                case .diagnostics:
                    verifyGroup
                    credentialRefreshGroup
                    webUsageGroup
                    logsGroup
                }
            }
        }
        .onChange(of: showRestoreBackupSheet) { _, newValue in
            if newValue {
                presentBackupWindow()
            } else {
                backupWindow.close()
                cloudSync.clearBackups()
                restoreSelectedSlot = nil
                restoreConfirmSlot = nil
            }
        }
        .onChange(of: showRestorePreviewSheet) { _, newValue in
            if newValue {
                presentPreviewWindow()
            } else {
                previewWindow.close()
                cloudSync.clearPreview()
                restorePreviewSelection = []
                restorePreviewImportPath = nil
            }
        }
    }

    private func presentBackupWindow() {
        backupWindow.onClose = { showRestoreBackupSheet = false }
        backupWindow.show(title: "Restore from backup", size: NSSize(width: 500, height: 460)) {
            AnyView(
                RestoreBackupSheet(
                    showRestoreBackupSheet: $showRestoreBackupSheet,
                    restoreBackupPassphrase: $restoreBackupPassphrase,
                    restoreSelectedSlot: $restoreSelectedSlot,
                    restoreConfirmSlot: $restoreConfirmSlot,
                    restorePreviewSlot: $restorePreviewSlot,
                    restorePreviewPassphrase: $restorePreviewPassphrase,
                    restorePreviewSelection: $restorePreviewSelection,
                    showRestorePreviewSheet: $showRestorePreviewSheet
                )
                .environmentObject(cloudSync)
            )
        }
    }

    private func presentPreviewWindow() {
        previewWindow.onClose = { showRestorePreviewSheet = false }
        let title = restorePreviewImportPath == nil ? "Review restore" : "Review import"
        previewWindow.show(title: title, size: NSSize(width: 640, height: 520)) {
            AnyView(
                RestorePreviewSheet(
                    showRestorePreviewSheet: $showRestorePreviewSheet,
                    restorePreviewSlot: $restorePreviewSlot,
                    restorePreviewPassphrase: $restorePreviewPassphrase,
                    restorePreviewSelection: $restorePreviewSelection,
                    restorePreviewImportPath: $restorePreviewImportPath
                )
                .environmentObject(cloudSync)
                .environmentObject(store)
            )
        }
    }

    /// Push the local bundle. Uses NSAlert (not a SwiftUI sheet) for the
    /// passphrase because the menu-bar popover dismisses on focus loss —
    /// any sheet hosted inside it loses its @State during the modal, leaving
    /// "Save" disabled and the password field detached from its binding.
    /// NSAlert.runModal() escapes the popover and returns synchronously.
    private func runPushPrompt() {
        guard let pass = CloudPassphrasePrompt.run(
            intent: .push,
            initial: cloudSync.loadPassphrase() ?? ""
        ) else { return }
        Task { await cloudSync.push(passphrase: pass) }
    }

    /// Export the local bundle to a user-chosen file (for sharing across
    /// Apple IDs). The file is AES-256-GCM encrypted with the user's
    /// passphrase — safe to deliver via AirDrop, Slack, etc.
    private func runExportPrompt() {
        guard let pass = CloudPassphrasePrompt.run(
            intent: .push,
            initial: cloudSync.loadPassphrase() ?? ""
        ) else { return }

        let panel = NSSavePanel()
        panel.title = "Export Claude Bar bundle"
        panel.nameFieldStringValue = "claude-bar-bundle-\(Self.exportDateSlug()).cbb"
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard PopoverModal.runPanel(panel) == .OK, let url = panel.url else { return }

        Task { await cloudSync.exportBundle(passphrase: pass, destPath: url.path) }
    }

    /// Import a bundle file received from another Apple ID. Opens the same
    /// preview UI as iCloud-restore so the user can pick which accounts to
    /// bring in (anti-rollback bypassed; iCloud sync state is untouched).
    private func runImportPrompt() {
        let panel = NSOpenPanel()
        panel.title = "Import Claude Bar bundle"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        guard PopoverModal.runPanel(panel) == .OK, let url = panel.url else { return }

        guard let pass = CloudPassphrasePrompt.run(
            intent: .pull,
            initial: cloudSync.loadPassphrase() ?? ""
        ) else { return }

        restorePreviewSlot = 0
        restorePreviewPassphrase = pass
        restorePreviewSelection = []
        restorePreviewImportPath = url.path
        showRestorePreviewSheet = true
        Task {
            await cloudSync.importPreview(passphrase: pass, srcPath: url.path)
            restorePreviewSelection = Set(
                cloudSync.previewRows
                    .filter { $0.status != "localOnly" }
                    .map { $0.identity }
            )
        }
    }

    private static func exportDateSlug() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    /// Pull/restore from iCloud. Passphrase via NSAlert; the follow-up
    /// preview UI (account picker) is launched directly afterwards.
    private func runPullPrompt() {
        guard let pass = CloudPassphrasePrompt.run(
            intent: .pull,
            initial: cloudSync.loadPassphrase() ?? ""
        ) else { return }
        restorePreviewSlot = 0
        restorePreviewPassphrase = pass
        restorePreviewSelection = []
        showRestorePreviewSheet = true
        Task {
            await cloudSync.preview(slot: 0, passphrase: pass)
            restorePreviewSelection = Set(
                cloudSync.previewRows
                    .filter { $0.status != "localOnly" }
                    .map { $0.identity }
            )
        }
    }

    private var iCloudGroup: some View {
        SettingsGroup(
            "iCloud Sync",
            subtitle: "Sync the account roster (email · nickname · organization) across Macs that share your Apple ID. Credentials are never uploaded — each new Mac still needs its own `claude /login`. MCP connector tokens and claude.ai web cookies also stay local-only."
        ) {
            Toggle(isOn: Binding(
                get: { iCloudSyncEnabled },
                set: { cloudSync.setSyncEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable iCloud sync")
                        .font(.system(size: 12, weight: .medium))
                    Text("Off by default after every update. When on, only account metadata roams — open Claude Bar on a second Mac and you'll see the same account names ready to be filled in. No OAuth tokens, no MCP credentials, no cookies leave this Mac. Turning sync off skips every Keychain read, so Sparkle updates don't trigger password prompts.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if iCloudSyncEnabled {
                iCloudGroupActiveBody
            }
        }
    }

    @ViewBuilder
    private var iCloudGroupActiveBody: some View {
        if let status = cloudSync.status, status.exists {
            HStack(spacing: 6) {
                SettingsBadge(text: "BUNDLE FOUND", color: .green)
                if let pushed = status.pushedAt {
                    Text("Last pushed \(SettingsRelativeDate.format(pushed))")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let n = status.backupCount, n > 0 {
                    Text("· \(n) backup\(n == 1 ? "" : "s")")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let seq = status.lastSeenSeq, seq > 0 {
                    Text("· seq \(seq)")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            autoSyncStatusLine
        } else {
            SettingsBadge(text: "NOT SET UP", color: .secondary)
        }
        if let err = cloudSync.lastError {
            Text(err).font(.caption).foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        if cloudSync.status?.exists == true {
            // Bundle already enabled — auto-sync handles the steady state.
            // Manual buttons are for force-sync, recovery, and rotation.
            HStack(spacing: 8) {
                Button {
                    runPushPrompt()
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered).disabled(cloudSync.isBusy)
                .help("Background sync runs every ~6h. Click to push your latest changes to iCloud immediately, or to rotate the passphrase.")

                Button {
                    runPullPrompt()
                } label: {
                    Label("Restore", systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(.bordered).disabled(cloudSync.isBusy)

                if (cloudSync.status?.backupCount ?? 0) > 0 {
                    Button {
                        restoreBackupPassphrase = cloudSync.loadPassphrase() ?? ""
                        restoreSelectedSlot = nil
                        showRestoreBackupSheet = true
                        Task {
                            await cloudSync.listBackups(passphrase: restoreBackupPassphrase)
                        }
                    } label: {
                        Label("Restore from backup…", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.bordered).disabled(cloudSync.isBusy)
                }

                Spacer()

                Button("Forget", role: .destructive) {
                    Task { await cloudSync.forget() }
                }
                .buttonStyle(.borderless).disabled(cloudSync.isBusy)
            }
        } else {
            // No bundle yet — the prominent CTA is the one-time enablement.
            // Without this click the passphrase is never saved and auto-sync
            // can't kick in.
            HStack(spacing: 8) {
                Button {
                    runPushPrompt()
                } label: {
                    Label("Enable sync", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(.borderedProminent).disabled(cloudSync.isBusy)
            }
        }
    }

    /// Status chip showing how the most recent background pull→refresh→push
    /// cycle went. Four states: never-run, ok, degraded (last attempt failed
    /// but a recent success exists), broken (no success in 12h+). Lets the
    /// user notice silently-failing sync before it bites them.
    @ViewBuilder
    private var autoSyncStatusLine: some View {
        let now = Date().timeIntervalSince1970
        let hasAttempt = lastAutoSyncAt > 0
        let hasSuccess = lastAutoSyncSuccessAt > 0
        let attemptFailed = !lastAutoSyncError.isEmpty
        let successAge = hasSuccess ? now - lastAutoSyncSuccessAt : .infinity
        let isBroken = attemptFailed && successAge > 12 * 3600

        if !hasAttempt {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text("Background sync will run within ~6h.")
                    .font(.caption).foregroundColor(.secondary)
            }
        } else if isBroken {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hasSuccess
                         ? "Sync failing for \(Int(successAge / 3600))h+"
                         : "Sync has never succeeded")
                        .font(.caption).foregroundColor(.red)
                    Text(lastAutoSyncError)
                        .font(.caption2).foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if attemptFailed, let successDate = hasSuccess ? Date(timeIntervalSince1970: lastAutoSyncSuccessAt) : nil {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Last sync failed · last ok \(SettingsRelativeDate.format(successDate))")
                        .font(.caption).foregroundColor(.orange)
                    Text(lastAutoSyncError)
                        .font(.caption2).foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if hasSuccess {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                Text("Auto-synced \(SettingsRelativeDate.format(Date(timeIntervalSince1970: lastAutoSyncSuccessAt)))")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var bundleFileGroup: some View {
        SettingsGroup(
            "Bundle file (cross-Apple-ID share)",
            subtitle: "Export an encrypted bundle file to share accounts with someone on a different iCloud. Recipient imports it with the same passphrase — no iCloud sync involved."
        ) {
            HStack(spacing: 8) {
                Button {
                    runExportPrompt()
                } label: {
                    Label("Export to file…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered).disabled(cloudSync.isBusy)

                Button {
                    runImportPrompt()
                } label: {
                    Label("Import from file…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered).disabled(cloudSync.isBusy)
            }
        }
    }

    private var verifyGroup: some View {
        SettingsGroup("Account verification", subtitle: "Checks the keychain backup, OAuth refresh, and Anthropic usage API for every managed account.") {
            Button {
                verifyCoordinator.begin()
            } label: {
                Label("Verify all accounts", systemImage: "checkmark.shield")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var credentialRefreshGroup: some View {
        SettingsGroup(
            "Credential refresh",
            subtitle: "Rotate OAuth tokens for inactive accounts ahead of schedule. The widget already refreshes every 6 hours in the background; only press this if you suspect a token has gone stale."
        ) {
            Button {
                runForceRefresh()
            } label: {
                if isForceRefreshing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Refreshing…")
                    }
                } else {
                    Label("Force refresh tokens now", systemImage: "key.fill")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isForceRefreshing || forceRefreshCooldownActive)

            if forceRefreshCooldownActive {
                Text("Recently refreshed — wait a few seconds before rotating again.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let outcome = forceRefreshOutcome {
                Label(outcome.message, systemImage: outcome.iconName)
                    .font(.caption)
                    .foregroundColor(outcome.iconColor)
            }
        }
    }

    private func runForceRefresh() {
        guard !isForceRefreshing, !forceRefreshCooldownActive else { return }
        isForceRefreshing = true
        Task {
            var outcome: ForceRefreshOutcome = .success
            do {
                try await store.client.refreshAllTokens()
            } catch {
                let detail = error.localizedDescription
                if detail.localizedCaseInsensitiveContains("rate limited") {
                    outcome = .rateLimited(detail: detail)
                } else {
                    outcome = .error(detail: detail)
                }
            }
            await store.refreshNow()
            forceRefreshOutcome = outcome
            isForceRefreshing = false
            if outcome.triggerCooldown {
                forceRefreshCooldownActive = true
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(Self.forceRefreshCooldownSec) * 1_000_000_000)
                    forceRefreshCooldownActive = false
                }
            }
        }
    }

    private var webUsageGroup: some View {
        SettingsGroup("Web usage diagnostics", subtitle: "Each account has its own embedded web profile. Web sessions sync separately through iCloud Keychain by account email.") {
            if let accounts = store.snapshot?.accounts, !accounts.isEmpty {
                ForEach(accounts) { acc in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(acc.account.displayName)
                                .font(.system(size: 12, weight: .medium))
                            Text(webFallback.state(for: acc.account).label)
                                .font(.caption)
                                .foregroundColor(webUsageColor(for: acc.account))
                                .lineLimit(1)
                        }
                        Spacer()
                        Button(webFallback.isLinked(acc.account) ? "Open" : "Connect") {
                            webFallback.open(for: acc)
                        }
                        .controlSize(.small)
                        if webFallback.isLinked(acc.account) {
                            Button("Disconnect", role: .destructive) {
                                Task { await webFallback.disconnect(acc.account) }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            } else {
                Text("Add an account before linking web usage.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func webUsageColor(for account: AccountDTO) -> Color {
        switch webFallback.state(for: account) {
        case .connected: return .green
        case .fallback: return .orange
        case .linked, .notLinked: return .secondary
        }
    }

    // MARK: - Logs & diagnostics

    private var logsGroup: some View {
        SettingsGroup(
            "Logs & diagnostics",
            subtitle: "Logs and crash reports stay on your Mac unless you click Send. Stored under ~/Library/Logs/ClaudeBar/."
        ) {
            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(DiagnosticsLogger.shared.logDirectory)
                } label: {
                    Label("Open log folder", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Button {
                    let text = DiagnosticsLogger.shared.tail(lines: 200)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy last 200 lines", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)

                Button {
                    sendDiagnosticsByMail()
                } label: {
                    Label("Send diagnostics…", systemImage: "envelope")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Opens the user's default mail client with a pre-filled message
    /// containing the last 200 log lines. Mail recipient is the project
    /// author. Privacy: user reviews + edits before sending.
    private func sendDiagnosticsByMail() {
        let log = DiagnosticsLogger.shared.tail(lines: 200)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let body = """
        App version: \(version)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)

        --- Recent log (last 200 lines) ---
        \(log)
        """
        let subject = "Claude Bar diagnostics"
        let q: (String) -> String = { s in
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        }
        let url = "mailto:nc.thanhngo@gmail.com?subject=\(q(subject))&body=\(q(body))"
        if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }
}

// MARK: - Shared cosmetics used by diagnostics + restore sheets

struct SettingsBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .clipShape(Capsule())
    }
}

enum SettingsRelativeDate {
    static func format(_ d: Date) -> String {
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }
}
