import SwiftUI

/// Peer list with a clear SERVER/DEV chip, live status, agent version (+ "cũ"
/// badge), rename, a per-server Terminal menu, and a reverse-support toggle on
/// dev machines.
struct NetbirdPeerListView: View {
    @ObservedObject var coord: NetbirdCoordinator
    let palette: BriefingPalette
    @State private var editingPeer: NBPeer?
    @State private var renameText = ""
    @State private var deletingPeer: NBPeer?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Máy trong mạng").font(.system(size: 15, weight: .bold)).foregroundColor(palette.ink)
            VStack(spacing: 0) {
                let peers = coord.overview?.peers ?? []
                ForEach(peers) { peer in
                    row(peer)
                    if peer.id != peers.last?.id {
                        Rectangle().fill(palette.line).frame(height: 1)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(palette.raisedSurface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
        }
        .sheet(item: $editingPeer) { peer in renameSheet(peer) }
        .confirmationDialog(
            deletingPeer.map { "Xoá máy “\($0.name)” khỏi NetBird?" } ?? "",
            isPresented: Binding(get: { deletingPeer != nil }, set: { if !$0 { deletingPeer = nil } }),
            titleVisibility: .visible
        ) {
            Button("Xoá khỏi NetBird", role: .destructive) {
                if let p = deletingPeer { Task { await coord.deletePeer(p) } }
                deletingPeer = nil
            }
            Button("Huỷ", role: .cancel) { deletingPeer = nil }
        } message: {
            Text("Máy rời mạng mesh và các setup key đã dùng cũng bị thu hồi — máy này KHÔNG tự vào lại được. Muốn cài lại phải cấp key mới. Khác với “bỏ khỏi nhóm” (máy vẫn ở trong mạng).")
        }
    }

    private func row(_ peer: NBPeer) -> some View {
        let isServer = coord.serverGroup(of: peer) != nil
        let devGroup = coord.devGroup(of: peer)
        return HStack(spacing: 12) {
            Circle().fill(peer.connected ? palette.sage : palette.ink3).frame(width: 8, height: 8)
            roleChip(isServer: isServer, isDev: devGroup != nil,
                     accent: (coord.serverGroup(of: peer) ?? devGroup).flatMap { coord.color(forGroup: $0) })
            VStack(alignment: .leading, spacing: 3) {
                Text(peer.name).font(.system(size: 13, weight: .medium)).foregroundColor(palette.ink)
                Text("\(peer.os) · \(peer.ip)").font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.ink3)
                accessSummary(peer, isServer: isServer)
            }
            Button { editingPeer = peer; renameText = peer.name } label: {
                Image(systemName: "pencil").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundColor(palette.ink3)
            .help("Đổi tên máy")
            groupMenu(peer)
            Button { deletingPeer = peer } label: {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundColor(palette.ink3)
            .help("Xoá máy khỏi NetBird")
            .disabled(coord.busy)
            Spacer()
            versionTag(peer.version)
            if isServer { terminalMenu(peer) }
            if let dg = devGroup { supportToggle(devGroup: dg) }
        }
        .padding(.vertical, 10).padding(.horizontal, 16)
    }

    /// One-line "where is this machine + what it connects to", derived from the
    /// live policies. For servers: who can get in. For everything else: which
    /// servers it can SSH into. Answers the "I see hailong but where is it?"
    private func accessSummary(_ peer: NBPeer, isServer: Bool) -> some View {
        Text(accessSummaryText(peer, isServer: isServer))
            .font(.system(size: 11)).foregroundColor(palette.ink2).lineLimit(1)
    }

    private func accessSummaryText(_ peer: NBPeer, isServer: Bool) -> String {
        let groups = coord.memberGroups(of: peer)
        let groupText = groups.isEmpty ? "chưa thuộc nhóm" : "nhóm \(groups.joined(separator: ", "))"
        if isServer {
            let by = coord.accessorsOf(peer)
            return "\(groupText) · ← \(by.isEmpty ? "chưa ai được vào" : by.joined(separator: ", "))"
        }
        let reach = coord.reachableServers(of: peer)
        return "\(groupText) · → \(reach.isEmpty ? "chưa vào được server nào" : reach.joined(separator: ", "))"
    }

    private func roleChip(isServer: Bool, isDev: Bool, accent: Color?) -> some View {
        let (text, base): (String, Color) =
            isServer ? ("SERVER", palette.moss)
            : isDev   ? ("DEV", palette.gold)
            : ("—", palette.ink3)
        let color = accent ?? base
        return Text(text)
            .font(.system(size: 9, weight: .bold)).tracking(0.3)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundColor(color)
            .frame(width: 56)
    }

    @ViewBuilder private func versionTag(_ v: String) -> some View {
        if !v.isEmpty {
            let stale = !coord.latestVersion.isEmpty && v != coord.latestVersion
            HStack(spacing: 5) {
                Text("v\(v)").font(.system(size: 10, design: .monospaced)).foregroundColor(palette.ink2)
                if stale {
                    Text("cũ").font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(palette.gold.opacity(0.18)))
                        .foregroundColor(palette.gold)
                }
            }
        }
    }

    /// Per-machine group membership editor: tick a group to add this machine,
    /// untick to remove. This is how a machine gets filed into a dev/server
    /// group (the matrix only shows groups, not individual machines).
    private func groupMenu(_ peer: NBPeer) -> some View {
        let groups = coord.assignableGroups
        return Menu {
            if groups.isEmpty {
                Text("Chưa có nhóm nào — tạo nhóm ở ma trận trước.")
            } else {
                Section("Nhóm của máy này") {
                    ForEach(groups) { g in
                        let inGroup = peer.groupNames.contains(g.name)
                        Button {
                            Task {
                                if inGroup { await coord.removePeer(peer, fromGroup: g.name) }
                                else { await coord.assignPeer(peer, toGroup: g.name) }
                            }
                        } label: {
                            Label(roleLabel(g.name), systemImage: inGroup ? "checkmark" : "circle")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "folder.badge.plus").font(.system(size: 12))
        }
        .menuStyle(.borderlessButton).fixedSize().frame(width: 30)
        .help("Thêm / bỏ máy khỏi nhóm")
        .disabled(coord.busy)
    }

    /// "name (server)" / "name (dev)" so the picker shows each group's role.
    private func roleLabel(_ name: String) -> String {
        switch coord.roles[name] {
        case .server: return "\(name) (server)"
        case .dev:    return "\(name) (dev)"
        case .none:   return name
        }
    }

    private func terminalMenu(_ peer: NBPeer) -> some View {
        let host = peer.dnsLabel.isEmpty ? peer.name : peer.dnsLabel
        return Menu {
            ForEach(NetbirdAccountsStore.usernames(for: host), id: \.self) { user in
                Button(user) { coord.openTerminal(user: user, host: host) }
            }
        } label: {
            Image(systemName: "terminal").font(.system(size: 12))
        }
        .menuStyle(.borderlessButton).fixedSize().frame(width: 34)
        .help("Mở terminal tới \(host)")
    }

    private func supportToggle(devGroup: String) -> some View {
        let on = coord.reverseSupportEnabled(dev: devGroup)
        return Button {
            Task { await coord.setReverseSupport(dev: devGroup, on: !on) }
        } label: {
            Image(systemName: on ? "lifepreserver.fill" : "lifepreserver")
                .font(.system(size: 12)).foregroundColor(on ? palette.coral : palette.ink3)
        }
        .buttonStyle(.plain).disabled(coord.busy)
        .help(on ? "Tắt quyền hỗ trợ (SSH ngược)" : "Cho phép tôi SSH vào máy này")
    }

    private func renameSheet(_ peer: NBPeer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Đổi tên máy").font(.system(size: 16, weight: .semibold))
            TextField("Tên máy", text: $renameText).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Huỷ") { editingPeer = nil }
                Button("Lưu") {
                    Task { await coord.renamePeer(peer, to: renameText); editingPeer = nil }
                }
                .buttonStyle(.borderedProminent).disabled(renameText.isEmpty)
            }
        }
        .padding(20).frame(width: 360)
    }
}
