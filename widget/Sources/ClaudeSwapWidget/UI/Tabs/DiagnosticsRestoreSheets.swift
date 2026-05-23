import SwiftUI

// Pick an older bundle slot to roll back to. Slot 0 is current; higher slots
// are progressively older ring-buffer copies. Selection routes through the
// preview sheet so the user picks specific accounts to overwrite.
struct RestoreBackupSheet: View {
    @EnvironmentObject var cloudSync: CloudSyncCoordinator

    @Binding var showRestoreBackupSheet: Bool
    @Binding var restoreBackupPassphrase: String
    @Binding var restoreSelectedSlot: Int?
    @Binding var restoreConfirmSlot: Int?
    @Binding var restorePreviewSlot: Int
    @Binding var restorePreviewPassphrase: String
    @Binding var restorePreviewSelection: Set<String>
    @Binding var showRestorePreviewSheet: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore from backup").font(.headline)
            Text("Pick an older bundle to roll back to. Slot 0 is the current bundle; higher slots are progressively older ring-buffer copies. The current bundle is overwritten on restore.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Saved passphrase may be wrong (rotated on another device) — every
            // backup row would come back undecrypted. Allow re-entering to retry.
            if !cloudSync.isBusy && !cloudSync.backups.isEmpty && cloudSync.backups.allSatisfy({ !$0.decrypted }) {
                Text("Couldn't decrypt with the saved passphrase. Enter a different one to reveal seq and pushed-at for each backup.")
                    .font(.caption2).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                SecureField("Passphrase", text: $restoreBackupPassphrase)
                    .textFieldStyle(.roundedBorder)
                Button("Decrypt") {
                    Task { await cloudSync.listBackups(passphrase: restoreBackupPassphrase) }
                }
                .buttonStyle(.bordered).disabled(restoreBackupPassphrase.isEmpty || cloudSync.isBusy)
            }

            if cloudSync.isBusy && cloudSync.backups.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Loading…").font(.caption) }
            } else if cloudSync.backups.isEmpty {
                Text("No bundle copies found.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(cloudSync.backups) { b in
                            BackupRow(backup: b, selectedSlot: $restoreSelectedSlot)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: .infinity)
            }

            if let err = cloudSync.lastError {
                Text(err).font(.caption).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Close") { showRestoreBackupSheet = false }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    if let slot = restoreSelectedSlot {
                        restoreConfirmSlot = slot
                    }
                } label: {
                    Label("Restore selected", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderedProminent)
                .disabled(restoreSelectedSlot == nil || cloudSync.isBusy)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Restore from slot \(restoreConfirmSlot ?? 0)?",
            isPresented: Binding(
                get: { restoreConfirmSlot != nil },
                set: { if !$0 { restoreConfirmSlot = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Choose accounts…") {
                guard let slot = restoreConfirmSlot else { return }
                let pass = restoreBackupPassphrase.isEmpty
                    ? (cloudSync.loadPassphrase() ?? "")
                    : restoreBackupPassphrase
                restoreConfirmSlot = nil
                showRestoreBackupSheet = false
                restorePreviewSlot = slot
                restorePreviewPassphrase = pass
                restorePreviewSelection = []
                showRestorePreviewSheet = true
                Task {
                    await cloudSync.preview(slot: slot, passphrase: pass)
                    restorePreviewSelection = Set(
                        cloudSync.previewRows
                            .filter { $0.status != "localOnly" }
                            .map { $0.identity }
                    )
                }
            }
            Button("Cancel", role: .cancel) { restoreConfirmSlot = nil }
        } message: {
            Text("You'll see a side-by-side table of local vs bundle accounts and choose which ones to restore. Anti-rollback is bypassed for backup slots and the sync state is rewound to this bundle's seq.")
        }
    }
}

private struct BackupRow: View {
    let backup: CswClient.CloudBackupInfoDTO
    @Binding var selectedSlot: Int?

    var body: some View {
        let selected = selectedSlot == backup.slot
        Button {
            selectedSlot = backup.slot
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(backup.slot == 0 ? "Current" : "Backup #\(backup.slot)")
                            .font(.system(size: 12, weight: .semibold))
                        if backup.decrypted, let seq = backup.seq {
                            Text("seq \(seq)").font(.caption).foregroundColor(.secondary)
                        }
                        if let n = backup.accountCount {
                            Text("· \(n) account\(n == 1 ? "" : "s")")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    HStack(spacing: 6) {
                        if let pushed = backup.pushedAtInBundle {
                            Text("Pushed \(SettingsRelativeDate.format(pushed))")
                                .font(.caption2).foregroundColor(.secondary)
                        } else {
                            Text("Modified \(SettingsRelativeDate.format(backup.fileModTime))")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Text("· \(backup.sizeKb) KB")
                            .font(.caption2).foregroundColor(.secondary)
                        if !backup.decrypted {
                            Text("· encrypted").font(.caption2).foregroundColor(.orange)
                        }
                    }
                }
                Spacer()
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Side-by-side table of local vs bundle accounts. User ticks which incoming
// accounts to overwrite/import; local-only rows are unselectable.
//
// Sources two flows: iCloud bundle slot (restorePreviewImportPath == nil) or
// an externally-supplied bundle file (path set, used for the cross-Apple-ID
// share feature). Headline + "Restore selected" button route through the
// right CloudSyncCoordinator call based on which is active.
struct RestorePreviewSheet: View {
    @EnvironmentObject var cloudSync: CloudSyncCoordinator
    @EnvironmentObject var store: AppStore

    @Binding var showRestorePreviewSheet: Bool
    @Binding var restorePreviewSlot: Int
    @Binding var restorePreviewPassphrase: String
    @Binding var restorePreviewSelection: Set<String>
    @Binding var restorePreviewImportPath: String?

    private var isImport: Bool { restorePreviewImportPath != nil }

    private var headlineText: String {
        if isImport { return "Review import" }
        return restorePreviewSlot == 0
            ? "Review restore"
            : "Review restore (backup #\(restorePreviewSlot))"
    }

    private var subtitleText: String {
        if isImport {
            return "Tick the accounts you want to bring in from the imported file. Local-only accounts stay untouched. Both-side rows are overwritten with the bundle's credentials if ticked. Your iCloud sync chain is not affected."
        }
        return "Tick the accounts you want to bring in from the cloud bundle. Local-only accounts stay untouched. Both-side rows are overwritten with the bundle's credentials if ticked."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(headlineText).font(.headline)
                Spacer()
                if cloudSync.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            if let path = restorePreviewImportPath {
                Text(path)
                    .font(.caption2.monospaced()).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Text(subtitleText)
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            tableHeader
            ScrollView {
                VStack(spacing: 4) {
                    if cloudSync.previewRows.isEmpty {
                        if cloudSync.isBusy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Decrypting bundle…").font(.caption).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                        } else if let err = cloudSync.lastError, !err.isEmpty {
                            Text(err)
                                .font(.caption).foregroundColor(.red)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("No accounts in this bundle.")
                                .font(.caption).foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                        }
                    } else {
                        ForEach(cloudSync.previewRows) { row in
                            PreviewRow(row: row, selection: $restorePreviewSelection)
                        }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: .infinity)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if let err = cloudSync.lastError {
                Text(err).font(.caption).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Select all incoming") {
                    restorePreviewSelection = Set(
                        cloudSync.previewRows
                            .filter { $0.status != "localOnly" }
                            .map { $0.identity }
                    )
                }
                .buttonStyle(.borderless).font(.caption)
                Button("Deselect all") { restorePreviewSelection = [] }
                    .buttonStyle(.borderless).font(.caption)
                Spacer()
                Text("\(restorePreviewSelection.count) selected")
                    .font(.caption).foregroundColor(.secondary)
            }

            HStack {
                Button("Cancel") { showRestorePreviewSheet = false }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    let identities = Array(restorePreviewSelection)
                    let slot = restorePreviewSlot
                    let pass = restorePreviewPassphrase
                    let importPath = restorePreviewImportPath
                    showRestorePreviewSheet = false
                    Task {
                        if let path = importPath {
                            await cloudSync.importSelective(passphrase: pass, srcPath: path, identities: identities)
                        } else {
                            await cloudSync.pullSelective(slot: slot, passphrase: pass, identities: identities)
                        }
                        await store.refreshNow()
                    }
                } label: {
                    Label("\(isImport ? "Import" : "Restore") selected (\(restorePreviewSelection.count))",
                          systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(restorePreviewSelection.isEmpty || cloudSync.isBusy)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            Text("").frame(width: 22)
            Text("Account").font(.caption2).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Local Created").font(.caption2).foregroundColor(.secondary)
                .frame(width: 130, alignment: .leading)
            Text("Bundle Created").font(.caption2).foregroundColor(.secondary)
                .frame(width: 130, alignment: .leading)
            Text("Status").font(.caption2).foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
        }
        .padding(.horizontal, 8)
    }
}

private struct PreviewRow: View {
    let row: CswClient.CloudPreviewRowDTO
    @Binding var selection: Set<String>

    var body: some View {
        let isLocalOnly = row.status == "localOnly"
        let selected = selection.contains(row.identity)
        return HStack(spacing: 8) {
            if isLocalOnly {
                Image(systemName: "minus")
                    .foregroundColor(.secondary)
                    .frame(width: 22)
            } else {
                Button {
                    if selected { selection.remove(row.identity) }
                    else { selection.insert(row.identity) }
                } label: {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .foregroundColor(selected ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 22)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(row.email)
                    .font(.caption2).foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatDate(row.localCreatedAt))
                .font(.caption).foregroundColor(.secondary).monospacedDigit()
                .frame(width: 130, alignment: .leading)
            Text(formatDate(row.remoteCreatedAt))
                .font(.caption).foregroundColor(.secondary).monospacedDigit()
                .frame(width: 130, alignment: .leading)
            statusBadgeView
                .frame(width: 80, alignment: .leading)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(selected ? Color.accentColor.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var displayName: String {
        if let nick = row.nickname, !nick.isEmpty { return nick }
        if let org = row.organizationName, !org.isEmpty { return org }
        return row.email
    }

    private func formatDate(_ d: Date?) -> String {
        guard let d = d else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    @ViewBuilder
    private var statusBadgeView: some View {
        switch row.status {
        case "remoteOnly": SettingsBadge(text: "NEW", color: .blue)
        case "both":       SettingsBadge(text: "MATCH", color: .green)
        case "localOnly":  SettingsBadge(text: "LOCAL", color: .secondary)
        default:           SettingsBadge(text: row.status.uppercased(), color: .secondary)
        }
    }
}
