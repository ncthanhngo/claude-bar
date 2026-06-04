import SwiftUI

/// Backup & Restore Tools page. Left rail lists profiles; the detail edits the
/// selected profile (sources, destination, schedule, retention), runs read-only
/// preflight, and gates every server mutation behind a confirm sheet.
struct BackupRestoreView: View {
    @ObservedObject var store: BackupRestoreStore
    let palette: BriefingPalette

    @State private var showInstallSheet = false
    @State private var showRestoreSheet = false
    @State private var showRcloneSheet = false
    @State private var confirmRemoveID: String?

    var body: some View {
        HStack(spacing: 0) {
            BackupProfilesRail(store: store, palette: palette)
            Rectangle().fill(palette.line).frame(width: 1)
            Group {
                if let binding = draftBinding {
                    editor(binding)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 18)
        }
        .task { await store.load() }
        .overlay(alignment: .top) { errorBanner }
        .sheet(isPresented: $showInstallSheet) {
            BackupInstallConfirmSheet(store: store, palette: palette)
        }
        .sheet(isPresented: $showRestoreSheet) {
            BackupRestoreSheet(store: store, palette: palette)
        }
        .sheet(isPresented: $showRcloneSheet) {
            BackupRcloneSetupSheet(store: store, palette: palette)
        }
    }

    private var draftBinding: Binding<BackupProfile>? {
        guard store.draft != nil else { return nil }
        return Binding(get: { store.draft! }, set: { store.draft = $0 })
    }

    // MARK: detail editor

    @ViewBuilder private func editor(_ profile: Binding<BackupProfile>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard(profile)
                BackupSourcesEditor(profile: profile, palette: palette)
                destinationCard(profile)
                BackupScheduleRetentionEditor(profile: profile, palette: palette)
                BackupPreflightView(store: store, palette: palette)
                actionBar
                BackupHistoryView(store: store, palette: palette,
                                  onRestore: { showRestoreSheet = true })
                if !store.consoleOutput.isEmpty { consoleBox }
            }
            .padding(.trailing, 6)
            .padding(.bottom, 14)
        }
    }

    private func headerCard(_ profile: Binding<BackupProfile>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Tên hồ sơ", systemImage: "tag") {
                TextField("VD: Production server", text: profile.name)
                    .textFieldStyle(.roundedBorder)
            }
            field("Máy chủ (SSH)", systemImage: "server.rack") {
                if store.hosts.isEmpty {
                    Text("Chưa có host nào — thêm ở mục Netbird → SSH.")
                        .font(.system(size: 11)).foregroundColor(palette.coral)
                } else {
                    Picker("", selection: profile.sshHost) {
                        ForEach(store.hosts) { h in
                            Text(h.name + (h.hostName.map { " · \($0)" } ?? "")).tag(h.name)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.raisedSurface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
    }

    private func destinationCard(_ profile: Binding<BackupProfile>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Nơi lưu trữ", "externaldrive.connected.to.line.below")
            field("rclone remote", systemImage: "arrow.up.forward") {
                TextField("sharepoint:Backups/prod", text: profile.rcloneRemote)
                    .textFieldStyle(.roundedBorder)
            }
            field("Thư mục tạm trên server", systemImage: "folder") {
                TextField("/var/backups/claude-bar/…", text: profile.workDir)
                    .textFieldStyle(.roundedBorder)
            }
            Button {
                showRcloneSheet = true
            } label: {
                Label("Thiết lập rclone → SharePoint", systemImage: "wand.and.stars")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.bordered).tint(palette.plum)
            .disabled(store.selectedID == nil)
            .help(store.selectedID == nil ? "Lưu hồ sơ trước để thiết lập rclone." : "Tạo rclone remote trên server qua SSH.")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.raisedSurface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
    }

    // MARK: action bar

    private var actionBar: some View {
        let saved = store.selectedID != nil
        let ready = store.preflight?.ready == true
        return HStack(spacing: 8) {
            Button { Task { await store.save() } } label: {
                busyLabel(.saving, "Lưu", "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent).tint(palette.moss)
            .disabled(!canSave || store.busy != nil)

            Button { Task { await store.runPreflight() } } label: {
                busyLabel(.preflight, "Kiểm tra", "checklist")
            }
            .buttonStyle(.bordered).disabled(!saved || store.busy != nil)

            Button { showInstallSheet = true } label: {
                busyLabel(.installing, "Cài đặt lên server", "arrow.down.app")
            }
            .buttonStyle(.bordered).tint(palette.gold)
            .disabled(!saved || !ready || store.busy != nil)
            .help(ready ? "" : "Chạy Kiểm tra và đảm bảo mọi mục đạt trước khi cài.")

            Button { Task { await store.runNow() } } label: {
                busyLabel(.running, "Chạy ngay", "play.fill")
            }
            .buttonStyle(.bordered).disabled(!saved || store.busy != nil)

            Spacer()
        }
    }

    private var canSave: Bool {
        guard let d = store.draft else { return false }
        return !d.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !d.sshHost.isEmpty && !d.sources.isEmpty
    }

    private func busyLabel(_ kind: BackupRestoreStore.Busy, _ title: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            if store.busy == kind { ProgressView().controlSize(.small) }
            else { Image(systemName: icon).font(.system(size: 11)) }
            Text(title).font(.system(size: 12, weight: .medium))
        }
    }

    private var consoleBox: some View {
        ScrollView {
            Text(store.consoleOutput)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(palette.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxHeight: 180)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.paper2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1))
    }

    // MARK: empty + error

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.timemachine")
                .font(.system(size: 34)).foregroundColor(palette.ink3)
            Text("Chưa có hồ sơ sao lưu").font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundColor(palette.ink)
            Text("Tạo hồ sơ để cấu hình sao lưu Docker + DB lên SharePoint, cài lịch chạy hàng ngày trên server qua SSH.")
                .font(.system(size: 12)).foregroundColor(palette.ink3)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Button { store.newProfile() } label: {
                Label("Hồ sơ mới", systemImage: "plus")
            }.buttonStyle(.borderedProminent).tint(palette.moss)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var errorBanner: some View {
        if let err = store.lastError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                Text(err).font(.system(size: 11.5)).lineLimit(2)
                Spacer(minLength: 0)
                Button { store.lastError = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.coral))
            .padding(8)
        }
    }

    // MARK: small shared bits

    private func sectionTitle(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 13, weight: .semibold)).foregroundColor(palette.ink)
    }

    @ViewBuilder private func field<Content: View>(_ label: String, systemImage: String,
                                                   @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(label, systemImage: systemImage)
                .font(.system(size: 10.5, weight: .medium)).foregroundColor(palette.ink3)
            content()
        }
    }
}
