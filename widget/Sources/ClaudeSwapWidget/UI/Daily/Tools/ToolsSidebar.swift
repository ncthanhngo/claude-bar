import SwiftUI

/// A feature of the App tool — these are the sidebar rows shown when App is the
/// active tool. (Netbird is a separate top-level tool, not a page here.)
enum ToolsPage: String, CaseIterable, Identifiable {
    case uninstall
    case junk
    case largeFiles
    case disk
    case health
    case maintenance
    case backup

    var id: String { rawValue }

    var label: String {
        switch self {
        case .uninstall:   return "Gỡ ứng dụng"
        case .junk:        return "Quét rác"
        case .largeFiles:  return "File lớn"
        case .disk:        return "Phân tích đĩa"
        case .health:      return "Sức khoẻ máy"
        case .maintenance: return "Bảo trì"
        case .backup:      return "Sao lưu"
        }
    }

    var icon: String {
        switch self {
        case .uninstall:   return "trash.square"
        case .junk:        return "sparkles"
        case .largeFiles:  return "doc.viewfinder"
        case .disk:        return "chart.pie"
        case .health:      return "heart.text.square"
        case .maintenance: return "wrench.and.screwdriver"
        case .backup:      return "externaldrive.badge.timemachine"
        }
    }

    /// One-line description shown under the page title in the detail header.
    var subtitle: String {
        switch self {
        case .uninstall:   return "Liệt kê ứng dụng đã cài; gỡ kèm cache · preference · container."
        case .junk:        return "Cache, log, build artifact — dọn an toàn vào Thùng rác."
        case .largeFiles:  return "Tìm file lớn trong một thư mục để giải phóng dung lượng."
        case .disk:        return "Ổ đĩa và thư mục ngốn chỗ, trực quan bằng thanh dung lượng."
        case .health:      return "Đĩa · RAM · bảo mật · ổ cứng — chấm điểm, chỉ đọc."
        case .maintenance: return "Tác vụ bảo trì macOS một chạm."
        case .backup:      return "Sao lưu Docker + DB lên SharePoint qua SSH; lịch chạy hàng ngày trên server."
        }
    }
}

/// Left navigation rail listing the active tool's features.
struct ToolsSidebar: View {
    @Binding var page: ToolsPage
    let palette: BriefingPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("TÍNH NĂNG").font(.system(size: 10, weight: .bold)).tracking(1.1)
                .foregroundColor(palette.ink3)
                .padding(.horizontal, 12).padding(.bottom, 4)
            ForEach(ToolsPage.allCases) { row($0) }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .frame(width: 196, alignment: .leading)
    }

    private func row(_ p: ToolsPage) -> some View {
        let active = page == p
        return Button { page = p } label: {
            HStack(spacing: 10) {
                Image(systemName: p.icon).font(.system(size: 13)).frame(width: 18)
                    .foregroundColor(active ? palette.ink : palette.ink2)
                Text(p.label)
                    .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                    .foregroundColor(active ? palette.ink : palette.ink2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(active ? palette.ink.opacity(0.08) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? palette.line2 : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }
}
