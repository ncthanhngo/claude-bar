import SwiftUI

/// Read-only preflight checklist: docker / rclone / remote reachability / workdir
/// writable / scheduler available. Shown after the user runs "Kiểm tra".
struct BackupPreflightView: View {
    @ObservedObject var store: BackupRestoreStore
    let palette: BriefingPalette

    var body: some View {
        if let pf = store.preflight {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: pf.ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(pf.ready ? palette.moss : palette.gold)
                    Text(pf.ready ? "Sẵn sàng cài đặt" : "Còn mục chưa đạt")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(palette.ink)
                }
                ForEach(pf.checks) { c in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: c.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(c.ok ? palette.moss : palette.coral)
                        Text(label(for: c.name)).font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(palette.ink2).frame(width: 130, alignment: .leading)
                        Text(c.detail).font(.system(size: 11, design: .monospaced))
                            .foregroundColor(palette.ink3).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(palette.paper2))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
        }
    }

    private func label(for name: String) -> String {
        switch name {
        case "docker": return "Docker"
        case "rclone": return "rclone"
        case "remote": return "rclone remote"
        case "remote_reachable": return "Kết nối remote"
        case "workdir": return "Thư mục tạm"
        case "cron": return "cron"
        case "systemd": return "systemd"
        default:
            if name.hasPrefix("volume_") { return "Volume " + name.dropFirst("volume_".count) }
            return name
        }
    }
}
