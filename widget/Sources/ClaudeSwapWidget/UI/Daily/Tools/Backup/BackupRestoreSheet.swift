import SwiftUI

/// Destructive restore confirm. Pick a snapshot, then type the host name to
/// arm the restore — it overwrites live DB/volumes on the server.
struct BackupRestoreSheet: View {
    @ObservedObject var store: BackupRestoreStore
    let palette: BriefingPalette
    @Environment(\.dismiss) private var dismiss

    @State private var selected: String = ""
    @State private var typedConfirm: String = ""

    private var hostName: String { store.draft?.sshHost ?? "" }
    private var armed: Bool { !selected.isEmpty && typedConfirm == hostName }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Khôi phục từ snapshot").font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundColor(palette.ink)

            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(palette.coral)
                Text("Thao tác này GHI ĐÈ dữ liệu đang chạy trên \(hostName). Nên bấm “Chạy ngay” một bản sao lưu trước.")
                    .font(.system(size: 11.5)).foregroundColor(palette.ink2)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.coral.opacity(0.12)))

            if let snaps = store.snapshots, !snaps.isEmpty {
                Text("Chọn snapshot").font(.system(size: 11, weight: .medium)).foregroundColor(palette.ink3)
                Picker("", selection: $selected) {
                    Text("— chọn —").tag("")
                    ForEach(snaps.allPaths, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().pickerStyle(.menu)
            } else {
                Text("Không có snapshot nào trên remote. Hãy chạy backup trước.")
                    .font(.system(size: 12)).foregroundColor(palette.ink3)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Gõ tên host “\(hostName)” để xác nhận")
                    .font(.system(size: 11, weight: .medium)).foregroundColor(palette.ink3)
                TextField(hostName, text: $typedConfirm).textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    Task { await store.restore(snapshot: selected); dismiss() }
                } label: {
                    if store.busy == .restoring { ProgressView().controlSize(.small) }
                    else { Text("Khôi phục (ghi đè)") }
                }
                .buttonStyle(.borderedProminent).tint(palette.coral)
                .disabled(!armed || store.busy != nil)
            }
        }
        .padding(20).frame(width: 520)
    }
}
