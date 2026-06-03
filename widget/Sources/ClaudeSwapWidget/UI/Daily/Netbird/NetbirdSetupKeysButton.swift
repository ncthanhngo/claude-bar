import SwiftUI

/// Lists existing enrollment setup keys and lets the admin revoke one — a
/// leaked or finished key keeps enrolling machines until killed, so this is the
/// kill switch. Metadata only (no plaintext key); revoke deletes it in NetBird.
struct NetbirdSetupKeysButton: View {
    @ObservedObject var coord: NetbirdCoordinator
    let palette: BriefingPalette
    @State private var showing = false
    @State private var revoking: NBSetupKeyInfo?

    var body: some View {
        Button {
            showing = true
            Task { await coord.loadSetupKeys() }
        } label: {
            Image(systemName: "key.horizontal").font(.system(size: 13, weight: .semibold))
                .foregroundColor(palette.ink2)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.raisedSurface))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Quản lý / thu hồi setup key")
        .disabled(coord.busy)
        .popover(isPresented: $showing) { sheet }
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Setup key đang có").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { Task { await coord.loadSetupKeys() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundColor(palette.ink3).disabled(coord.busy)
            }
            Text("Thu hồi key để máy mới không enroll được bằng key đó nữa.")
                .font(.system(size: 11)).foregroundColor(palette.ink2)

            if coord.setupKeys.isEmpty {
                Text("Chưa có key nào (hoặc đang tải).")
                    .font(.system(size: 12)).foregroundColor(palette.ink3)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(coord.setupKeys) { k in
                        keyRow(k)
                        if k.id != coord.setupKeys.last?.id {
                            Rectangle().fill(palette.line).frame(height: 1)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 460)
        .confirmationDialog(
            revoking.map { "Thu hồi key “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            titleVisibility: .visible
        ) {
            Button("Thu hồi", role: .destructive) {
                if let k = revoking { Task { await coord.revokeSetupKey(k.id) } }
                revoking = nil
            }
            Button("Huỷ", role: .cancel) { revoking = nil }
        } message: {
            Text("Máy đã enroll trước đó vẫn ở trong mạng — chỉ chặn enroll mới bằng key này.")
        }
    }

    private func keyRow(_ k: NBSetupKeyInfo) -> some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor(k)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(k.name).font(.system(size: 12.5, weight: .medium)).foregroundColor(palette.ink)
                Text(subtitle(k)).font(.system(size: 10.5)).foregroundColor(palette.ink3)
            }
            Spacer()
            Button("Thu hồi") { revoking = k }
                .buttonStyle(.plain).foregroundColor(palette.coral)
                .font(.system(size: 11, weight: .semibold))
                .disabled(coord.busy || k.revoked)
        }
        .padding(.vertical, 8)
    }

    private func statusColor(_ k: NBSetupKeyInfo) -> Color {
        if k.revoked { return palette.ink3 }
        return k.valid ? palette.sage : palette.gold
    }

    private func subtitle(_ k: NBSetupKeyInfo) -> String {
        var parts: [String] = []
        parts.append(k.revoked ? "đã thu hồi" : (k.valid ? "còn hiệu lực" : "hết hạn/hết lượt"))
        let limit = k.usageLimit == 0 ? "∞" : "\(k.usageLimit)"
        parts.append("dùng \(k.usedTimes)/\(limit)")
        if k.ephemeral { parts.append("ephemeral") }
        return parts.joined(separator: " · ")
    }
}
