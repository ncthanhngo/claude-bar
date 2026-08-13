import SwiftUI

/// "Chờ duyệt" — machines enrolled via setup key that landed in the dev-pending
/// isolation group. Approve assigns them to a dev group (then the matrix grants
/// servers); reject removes the peer. Amber banner matching the editorial mockup.
struct NetbirdPendingView: View {
    @ObservedObject var coord: NetbirdCoordinator
    let palette: BriefingPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Circle().fill(palette.gold).frame(width: 9, height: 9)
                Text("Máy mới vừa kết nối")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundColor(palette.ink)
                Spacer()
                Text("CẦN BẠN DUYỆT")
                    .font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundColor(palette.gold)
            }
            ForEach(coord.pending) { peer in
                PendingRow(coord: coord, palette: palette, peer: peer)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [palette.gold.opacity(0.06), palette.gold.opacity(0.14)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.gold.opacity(0.45), lineWidth: 1))
    }
}

private struct PendingRow: View {
    @ObservedObject var coord: NetbirdCoordinator
    let palette: BriefingPalette
    let peer: NBPeer
    @State private var groupName = ""
    @State private var role: NBGroupRole = .dev

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 18)).foregroundColor(palette.ink2)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(palette.raisedSurface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name).font(.system(size: 13, weight: .semibold)).foregroundColor(palette.ink)
                Text("\(peer.ip) · \(peer.os)")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(palette.ink3)
            }
            Spacer()
            Picker("", selection: $role) {
                Text("Dev").tag(NBGroupRole.dev)
                Text("Server").tag(NBGroupRole.server)
            }
            .pickerStyle(.segmented).frame(width: 124).labelsHidden()
            TextField(role == .server ? "nhóm server" : "nhóm dev", text: $groupName)
                .textFieldStyle(.roundedBorder).frame(width: 130)
            Button("Từ chối") { Task { await coord.reject(peer: peer) } }
                .buttonStyle(.plain).foregroundColor(palette.ink3)
                .disabled(coord.busy)
            Button {
                Task { await coord.approve(peer: peer, group: groupName.isEmpty ? peer.name : groupName, role: role) }
            } label: {
                Text("Duyệt & gán").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(coord.busy)
        }
    }
}
