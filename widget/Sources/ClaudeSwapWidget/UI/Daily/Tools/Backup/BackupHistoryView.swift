import SwiftUI

/// Recent run status (from server status.json) plus a button to load available
/// snapshots and open the restore sheet.
struct BackupHistoryView: View {
    @ObservedObject var store: BackupRestoreStore
    let palette: BriefingPalette
    let onRestore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Lịch sử & khôi phục", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(palette.ink)
                Spacer()
                Button { Task { await store.refreshStatus() } } label: {
                    Label("Làm mới", systemImage: "arrow.clockwise").font(.system(size: 11))
                }.buttonStyle(.borderless).disabled(store.selectedID == nil)
                Button { Task { await store.loadSnapshots(); onRestore() } } label: {
                    Label("Khôi phục…", systemImage: "arrow.uturn.backward").font(.system(size: 11, weight: .medium))
                }.buttonStyle(.bordered).tint(palette.coral).disabled(store.selectedID == nil || store.busy != nil)
            }

            if store.recentRuns.isEmpty {
                Text("Chưa có lần chạy nào được ghi nhận. Bấm “Làm mới” sau khi đã cài đặt và chạy.")
                    .font(.system(size: 11)).foregroundColor(palette.ink3)
            } else {
                ForEach(store.recentRuns.prefix(8)) { run in
                    HStack(spacing: 8) {
                        Image(systemName: run.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.system(size: 11)).foregroundColor(run.ok ? palette.moss : palette.coral)
                        Text(run.ts).font(.system(size: 11, design: .monospaced)).foregroundColor(palette.ink2)
                        if run.ok, let b = run.bytes {
                            Text(humanBytes(b)).font(.system(size: 10.5)).foregroundColor(palette.ink3)
                        }
                        if !run.ok, let e = run.error {
                            Text(e).font(.system(size: 10.5)).foregroundColor(palette.coral).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.raisedSurface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
    }

    private func humanBytes(_ n: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(n); var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: i == 0 ? "%.0f %@" : "%.1f %@", v, units[i])
    }
}
