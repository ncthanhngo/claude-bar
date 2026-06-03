import SwiftUI

/// Read-only list of NetBird policies that DON'T match the app's simple
/// group→group convention (multi-rule / multi-group, or made outside the app).
/// They can't be edited from the matrix, so surfacing them here lets the admin
/// audit "who else has access" instead of those grants being invisible.
struct NetbirdExternalPoliciesView: View {
    @ObservedObject var coord: NetbirdCoordinator
    let palette: BriefingPalette

    private var policies: [NBPolicy] { coord.overview?.external ?? [] }

    var body: some View {
        if !policies.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").font(.system(size: 12)).foregroundColor(palette.ink2)
                    Text("Policy khác (ngoài ma trận)")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(palette.ink)
                    Text("chỉ xem").font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(palette.ink3.opacity(0.15))).foregroundColor(palette.ink3)
                }
                Text("Policy đa-rule/đa-nhóm hoặc tạo ngoài app. Sửa trong dashboard NetBird.")
                    .font(.system(size: 11)).foregroundColor(palette.ink3)
                VStack(spacing: 0) {
                    ForEach(policies) { p in
                        row(p)
                        if p.id != policies.last?.id { Rectangle().fill(palette.line).frame(height: 1) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(palette.raisedSurface))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
            }
        }
    }

    private func row(_ p: NBPolicy) -> some View {
        HStack(spacing: 10) {
            Circle().fill(p.enabled ? palette.sage : palette.ink3).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name.isEmpty ? "(không tên)" : p.name)
                    .font(.system(size: 12.5, weight: .medium)).foregroundColor(palette.ink)
                Text(summary(p)).font(.system(size: 10.5)).foregroundColor(palette.ink3).lineLimit(1)
            }
            Spacer()
            if !p.enabled {
                Text("tắt").font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(palette.ink3.opacity(0.15))).foregroundColor(palette.ink3)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
    }

    /// "N rule · src… → dst…" — a compact read-out of the first rule's groups.
    private func summary(_ p: NBPolicy) -> String {
        let rules = p.rules ?? []
        guard let r = rules.first else { return "\(rules.count) rule" }
        let src = (r.sources ?? []).map(\.name).joined(separator: ", ")
        let dst = (r.destinations ?? []).map(\.name).joined(separator: ", ")
        let arrow = src.isEmpty && dst.isEmpty ? "" : "  ·  \(src) → \(dst)"
        return "\(rules.count) rule\(arrow)"
    }
}
