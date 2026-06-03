import SwiftUI

/// How risky removing an item is — drives the green/amber badge in the Tools
/// cleanup tabs so the user can tell regenerable junk from their own data.
enum CleanupSafety: Hashable {
    case safe      // cache / build artifact / re-downloadable — regenerates
    case caution   // could be personal data or costly to rebuild — review first

    var label: String { self == .safe ? "An toàn" : "Cân nhắc" }
    var icon: String { self == .safe ? "checkmark.shield.fill" : "exclamationmark.triangle.fill" }
    func color(_ p: BriefingPalette) -> Color { self == .safe ? p.moss : p.gold }
}

/// Small pill showing whether removing an item is safe or needs a second look.
struct SafetyBadge: View {
    let safety: CleanupSafety
    let palette: BriefingPalette

    var body: some View {
        let c = safety.color(palette)
        return HStack(spacing: 3) {
            Image(systemName: safety.icon).font(.system(size: 8, weight: .bold))
            Text(safety.label).font(.system(size: 9, weight: .bold))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(c.opacity(0.15)))
        .foregroundColor(c)
        .help(safety == .safe
              ? "Tự tạo lại / tải lại được — xoá an toàn."
              : "Có thể là dữ liệu của bạn hoặc tốn công tạo lại — kiểm tra trước.")
    }
}
