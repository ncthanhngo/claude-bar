import SwiftUI

/// Confirm sheet shown before installing on the server. Previews the exact
/// scripts + schedule line that will be written, so the user sees what runs
/// before any server mutation (the "gate" for install).
struct BackupInstallConfirmSheet: View {
    @ObservedObject var store: BackupRestoreStore
    let palette: BriefingPalette
    @Environment(\.dismiss) private var dismiss

    @State private var artifacts: BackupArtifacts?
    @State private var loading = true
    @State private var showBackup = false
    @State private var showRestore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cài đặt lên server").font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundColor(palette.ink)
            Text("App sẽ ghi script + đăng ký lịch chạy trên máy chủ qua SSH. Xem trước nội dung trước khi xác nhận.")
                .font(.system(size: 12)).foregroundColor(palette.ink3)

            if loading {
                ProgressView("Đang dựng nội dung…").frame(maxWidth: .infinity)
            } else if let a = artifacts {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        infoRow("Máy chủ", store.draft?.sshHost ?? "—")
                        infoRow("Thư mục cài", a.installDir)
                        infoRow("Cơ chế", a.mechanism)
                        if a.mechanism == "cron" {
                            codeBlock("Cron", a.cronLine)
                        } else {
                            codeBlock("systemd .timer", a.timerUnit)
                        }
                        disclosure("backup.sh", a.backupScript, isOpen: $showBackup)
                        disclosure("restore.sh", a.restoreScript, isOpen: $showRestore)
                    }
                }.frame(maxHeight: 320)
            } else {
                Text("Không dựng được nội dung. Kiểm tra kết nối SSH.")
                    .font(.system(size: 12)).foregroundColor(palette.coral)
            }

            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await store.install(); dismiss() }
                } label: {
                    if store.busy == .installing { ProgressView().controlSize(.small) }
                    else { Text("Cài đặt") }
                }
                .buttonStyle(.borderedProminent).tint(palette.gold)
                .disabled(artifacts == nil || store.busy != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 560)
        .task {
            artifacts = await store.generate()
            loading = false
        }
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).font(.system(size: 11, weight: .medium)).foregroundColor(palette.ink3).frame(width: 90, alignment: .leading)
            Text(v).font(.system(size: 11, design: .monospaced)).foregroundColor(palette.ink2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func codeBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10.5, weight: .medium)).foregroundColor(palette.ink3)
            Text(body).font(.system(size: 10.5, design: .monospaced)).foregroundColor(palette.ink2)
                .textSelection(.enabled).padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.paper2))
        }
    }

    private func disclosure(_ title: String, _ script: String, isOpen: Binding<Bool>) -> some View {
        DisclosureGroup(isExpanded: isOpen) {
            Text(script).font(.system(size: 10, design: .monospaced)).foregroundColor(palette.ink2)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.paper2))
        } label: {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundColor(palette.ink)
        }
    }
}
