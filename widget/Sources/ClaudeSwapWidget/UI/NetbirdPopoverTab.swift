import SwiftUI

/// NetBird tab of the popover: every machine on the NetBird network, read from
/// the local client, each with a one-click "open SSH in Terminal". Each row
/// has a free-text label (who uses the machine) and an editable SSH username;
/// both are remembered.
struct NetbirdPopoverTab: View {
    @StateObject private var store = NetbirdPeerStore()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            content
        }
        .onAppear { Task { await store.refresh() } }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("NetBird")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary.opacity(0.78))
            if store.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            Spacer()
            if !store.peers.isEmpty {
                Text("\(store.peers.filter(\.isConnected).count)/\(store.peers.count) online")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundColor(.secondary).help("Tải lại danh sách máy")
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.error {
            message(error)
        } else if store.peers.isEmpty {
            message(store.isLoading ? "Đang tải…" : "Chưa có máy nào trong mạng.")
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.peers) { peer in
                        NetbirdPeerRow(
                            peer: peer,
                            user: store.user(for: peer),
                            label: store.label(for: peer),
                            onUserChange: { store.setUser($0, for: peer) },
                            onLabelChange: { store.setLabel($0, for: peer) },
                            sshCommand: { store.sshCommand(for: peer) },
                            onConnect: { store.connect(peer) }
                        )
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NetbirdPeerRow: View {
    let peer: NetbirdPeer
    let user: String
    let label: String
    let onUserChange: (String) -> Void
    let onLabelChange: (String) -> Void
    /// Evaluated at click time so it reflects the username just typed.
    let sshCommand: () -> String?
    let onConnect: () -> Void

    @State private var draftUser = ""
    @State private var draftLabel = ""
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(peer.isConnected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(peer.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        .layoutPriority(1)
                    // Saved as you type, so there is no Return key to forget.
                    TextField("Người dùng máy…", text: $draftLabel)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.orange)
                        .onChange(of: draftLabel) { _, new in onLabelChange(new) }
                        .help("Ghi chú để nhận diện máy (chỉ lưu trên máy này)")
                }
                Text(subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            TextField(NetbirdPeerStore.defaultUser, text: $draftUser)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                .onSubmit { commitUser() }
                .help("Tài khoản SSH cho máy này")
            Button(action: copyCommand) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(copied ? .green : .secondary)
            .pointingHandCursor()
            .help("Sao chép lệnh SSH vào \(peer.name)")
            Button(action: connect) {
                Image(systemName: "terminal").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(peer.isConnected ? .accentColor : .secondary.opacity(0.5))
            .disabled(!peer.isConnected)
            .pointingHandCursor(when: peer.isConnected)
            .help(peer.isConnected ? "SSH vào \(peer.name)" : "\(peer.name) đang offline")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .onAppear {
            draftUser = user == NetbirdPeerStore.defaultUser ? "" : user
            draftLabel = label
        }
    }

    private var subtitle: String {
        guard peer.isConnected else { return "\(peer.ip) · offline" }
        var parts = [peer.ip]
        if !peer.connectionType.isEmpty { parts.append(peer.connectionType) }
        if let ms = peer.latencyMs { parts.append("\(ms) ms") }
        return parts.joined(separator: " · ")
    }

    private func commitUser() { onUserChange(draftUser) }

    private func copyCommand() {
        commitUser()
        guard let cmd = sshCommand() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    /// Saves whatever is in the field first, so clicking Connect without
    /// pressing Return still uses the username on screen.
    private func connect() {
        commitUser()
        onConnect()
    }
}
