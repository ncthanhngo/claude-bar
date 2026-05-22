import SwiftUI

struct DiagnosticsTab: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var verifyCoordinator: VerifyCoordinator
    @EnvironmentObject var webFallback: WebFallbackCoordinator
    @EnvironmentObject var cloudSync: CloudSyncCoordinator

    @State private var showPassphraseEntry = false
    @State private var passphraseField = ""
    @State private var passphraseError: String?
    @State private var ideTestResult: String = ""
    @State private var ideTestRunning = false
    @State private var showRestoreBackupSheet = false
    @State private var restoreBackupPassphrase = ""
    @State private var restoreSelectedSlot: Int?
    @State private var restoreConfirmSlot: Int?
    @State private var showRestorePreviewSheet = false
    @State private var restorePreviewSlot: Int = 0
    @State private var restorePreviewPassphrase: String = ""
    @State private var restorePreviewSelection: Set<String> = []

    var body: some View {
        ScrollView {
            SettingsPage {
                iCloudGroup
                ideReloadTestGroup
                verifyGroup
                webUsageGroup
            }
        }
        .sheet(isPresented: $showPassphraseEntry) {
            PassphraseSheet(
                passphraseField: $passphraseField,
                passphraseError: $passphraseError,
                showPassphraseEntry: $showPassphraseEntry,
                restorePreviewSlot: $restorePreviewSlot,
                restorePreviewPassphrase: $restorePreviewPassphrase,
                restorePreviewSelection: $restorePreviewSelection,
                showRestorePreviewSheet: $showRestorePreviewSheet
            )
        }
        .sheet(isPresented: $showRestoreBackupSheet, onDismiss: {
            cloudSync.clearBackups()
            restoreSelectedSlot = nil
            restoreConfirmSlot = nil
        }) {
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
        }
        .sheet(isPresented: $showRestorePreviewSheet, onDismiss: {
            cloudSync.clearPreview()
            restorePreviewSelection = []
        }) {
            RestorePreviewSheet(
                showRestorePreviewSheet: $showRestorePreviewSheet,
                restorePreviewSlot: $restorePreviewSlot,
                restorePreviewPassphrase: $restorePreviewPassphrase,
                restorePreviewSelection: $restorePreviewSelection
            )
        }
    }

    private var iCloudGroup: some View {
        SettingsGroup("iCloud Sync", subtitle: "Encrypt and store accounts plus local MCP connectors in iCloud Drive. Restore on any Mac with the same Apple ID and passphrase.") {
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
            } else {
                SettingsBadge(text: "NOT SET UP", color: .secondary)
            }
            if let err = cloudSync.lastError {
                Text(err).font(.caption).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    passphraseField = cloudSync.loadPassphrase() ?? ""
                    passphraseError = nil
                    cloudSync.passphraseIntent = .push
                    showPassphraseEntry = true
                } label: {
                    Label(cloudSync.status?.exists == true ? "Push update" : "Enable sync",
                          systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(.borderedProminent).disabled(cloudSync.isBusy)

                if cloudSync.status?.exists == true {
                    Button {
                        passphraseField = cloudSync.loadPassphrase() ?? ""
                        passphraseError = nil
                        cloudSync.passphraseIntent = .pull
                        showPassphraseEntry = true
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

                    Button("Forget", role: .destructive) {
                        Task { await cloudSync.forget() }
                    }
                    .buttonStyle(.borderless).disabled(cloudSync.isBusy)
                }
            }
        }
    }

    private var ideReloadTestGroup: some View {
        SettingsGroup("IDE reload test", subtitle: "Runs the full reload flow now so you can see exactly what happens.") {
            Button {
                ideTestRunning = true
                ideTestResult = ""
                Task {
                    ideTestResult = await IDEReloader.diagnose()
                    ideTestRunning = false
                }
            } label: {
                Label(ideTestRunning ? "Testing..." : "Test IDE Reload", systemImage: "play.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(ideTestRunning)

            if !ideTestResult.isEmpty {
                Text(ideTestResult)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
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
