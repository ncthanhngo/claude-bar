import SwiftUI

/// Guided rclone → SharePoint setup. rclone's OneDrive backend needs an OAuth
/// token obtained interactively (browser). The user runs `rclone authorize` on
/// any machine with a browser, pastes the token here, picks a drive, and the
/// app writes the remote on the server over SSH.
struct BackupRcloneSetupSheet: View {
    @ObservedObject var store: BackupRestoreStore
    let palette: BriefingPalette
    @Environment(\.dismiss) private var dismiss

    @State private var tokenJSON = ""
    @State private var remoteName = "sharepoint"
    @State private var driveID = ""
    @State private var drivesOutput = ""

    private let authorizeCmd = #"rclone authorize "onedrive""#

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Thiết lập rclone → SharePoint").font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundColor(palette.ink)

            step(1, "Trên một máy có trình duyệt, chạy lệnh sau rồi đăng nhập Microsoft:")
            HStack {
                Text(authorizeCmd).font(.system(size: 11, design: .monospaced)).foregroundColor(palette.ink2)
                    .textSelection(.enabled)
                Spacer()
                Button { copy(authorizeCmd) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
            }
            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(palette.paper2))

            step(2, "Dán đoạn token JSON mà lệnh in ra:")
            TextEditor(text: $tokenJSON)
                .font(.system(size: 10.5, design: .monospaced)).frame(height: 70)
                .padding(4).overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.line, lineWidth: 1))

            step(3, "Liệt kê thư viện tài liệu (drive) trên SharePoint rồi chọn drive id:")
            HStack {
                Button { Task { drivesOutput = await store.listDrives(tokenJSON: tokenJSON) } } label: {
                    if store.busy == .rclone { ProgressView().controlSize(.small) }
                    else { Label("Liệt kê drives", systemImage: "list.bullet.rectangle") }
                }.buttonStyle(.bordered).disabled(tokenJSON.isEmpty || store.busy != nil)
                Spacer()
            }
            if !drivesOutput.isEmpty {
                ScrollView {
                    Text(drivesOutput).font(.system(size: 10, design: .monospaced)).foregroundColor(palette.ink2)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }.frame(height: 90).background(RoundedRectangle(cornerRadius: 8).fill(palette.paper2))
            }

            HStack(spacing: 10) {
                labeled("Tên remote") { TextField("sharepoint", text: $remoteName).textFieldStyle(.roundedBorder).frame(width: 130) }
                labeled("drive id") { TextField("b!xxxx…", text: $driveID).textFieldStyle(.roundedBorder) }
            }

            step(4, "Tạo remote trên server. Sau đó nhớ đặt rcloneRemote dạng “\(remoteName):Backups/…”.")

            HStack {
                Spacer()
                Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await store.createRemote(remote: remoteName, driveID: driveID, tokenJSON: tokenJSON) }
                } label: {
                    if store.busy == .rclone { ProgressView().controlSize(.small) }
                    else { Text("Tạo remote") }
                }
                .buttonStyle(.borderedProminent).tint(palette.plum)
                .disabled(tokenJSON.isEmpty || remoteName.isEmpty || driveID.isEmpty || store.busy != nil)
            }
        }
        .padding(20).frame(width: 560)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                .frame(width: 18, height: 18).background(Circle().fill(palette.plum))
            Text(text).font(.system(size: 12)).foregroundColor(palette.ink2)
            Spacer(minLength: 0)
        }
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundColor(palette.ink3)
            content()
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
