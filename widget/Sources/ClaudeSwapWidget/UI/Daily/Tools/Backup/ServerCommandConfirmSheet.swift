import SwiftUI

/// Gate sheet for an assistant-proposed command that mutates the server. The
/// user sees the exact command, its risk, and the target host before it runs —
/// the same trust model as the rest of the backup tab (user clicked + saw the
/// preview). Read-only commands never reach this sheet.
struct ServerCommandConfirmSheet: View {
    let command: ServerAgentStore.Command
    let host: String
    let palette: BriefingPalette
    let onRun: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: iconName).font(.system(size: 20)).foregroundColor(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Xác nhận chạy lệnh trên máy chủ")
                        .font(.system(size: 15, weight: .semibold, design: .serif)).foregroundColor(palette.ink)
                    Text("Máy chủ: \(host)").font(.system(size: 11.5)).foregroundColor(palette.ink3)
                }
                Spacer()
                riskBadge
            }

            ScrollView {
                Text(command.text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundColor(palette.ink).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .frame(maxHeight: 140)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.paper2))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1))

            if command.risk == .destructive {
                Label("Lệnh này có thể gây mất dữ liệu hoặc dừng dịch vụ. Kiểm tra kỹ trước khi chạy.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundColor(palette.coral)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Huỷ") { onCancel(); dismiss() }
                    .buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                Button { onRun(); dismiss() } label: {
                    Label("Chạy lệnh", systemImage: "play.fill").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent).tint(accent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var accent: Color { command.risk == .destructive ? palette.coral : palette.gold }
    private var iconName: String {
        command.risk == .destructive ? "exclamationmark.triangle.fill" : "terminal.fill"
    }

    private var riskBadge: some View {
        let text = command.risk == .destructive ? "Nguy hiểm" : "Thay đổi máy chủ"
        return Text(text).font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(accent.opacity(0.15)))
            .foregroundColor(accent)
    }
}
