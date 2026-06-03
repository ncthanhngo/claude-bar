import SwiftUI

/// Maintenance tab — one-click macOS housekeeping. Empty Trash is guarded by a
/// confirm; flush DNS prompts for the admin password.
struct MaintenanceView: View {
    @ObservedObject var runner: MaintenanceRunner
    let palette: BriefingPalette
    @State private var confirmTrash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = runner.status {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(palette.moss).font(.system(size: 11))
                    Text(s).font(.system(size: 11.5)).foregroundColor(palette.ink2)
                }
            }
            ScrollView {
                VStack(spacing: 0) {
                    card("trash", "Đổ Thùng rác", "Xoá vĩnh viễn mọi thứ trong Thùng rác.",
                         icon: "trash.fill", danger: true) { confirmTrash = true }
                    card("dns", "Flush DNS cache", "Xoá cache phân giải tên miền (cần mật khẩu admin).",
                         icon: "network") { runner.flushDNS() }
                    card("ls", "Dựng lại Launch Services", "Sửa menu “Mở bằng…” bị trùng/sai.",
                         icon: "arrow.triangle.2.circlepath") { runner.rebuildLaunchServices() }
                    card("font", "Xoá font cache", "Khắc phục font hiển thị lỗi.",
                         icon: "textformat") { runner.clearFontCache() }
                    card("dock", "Khởi động lại Dock", "Làm tươi thanh Dock.",
                         icon: "dock.rectangle") { runner.restartDock() }
                    card("finder", "Khởi động lại Finder", "Làm tươi Finder.",
                         icon: "macwindow", last: true) { runner.restartFinder() }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(palette.raisedSurface))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
            }
        }
        .confirmationDialog("Đổ sạch Thùng rác?", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Đổ Thùng rác", role: .destructive) { runner.emptyTrash() }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Thao tác này KHÔNG khôi phục được — khác với các thao tác dọn khác (chuyển vào Thùng rác).")
        }
    }

    private func card(_ id: String, _ title: String, _ desc: String, icon: String,
                      danger: Bool = false, last: Bool = false, _ action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14))
                    .foregroundColor(danger ? palette.coral : palette.ink2).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(palette.ink)
                    Text(desc).font(.system(size: 10.5)).foregroundColor(palette.ink3)
                }
                Spacer()
                if runner.working == id {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Chạy", action: action)
                        .buttonStyle(.bordered).tint(danger ? palette.coral : palette.moss)
                        .disabled(runner.working != nil)
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            if !last { Divider().overlay(palette.line) }
        }
    }
}
