import SwiftUI

/// Horizontal rail of SSH host pills. Loads from CswClient.sshList(); each
/// pill shows the host name + last-connected indicator. Clicking opens a
/// menu with "Ask Claude to tail logs / show uptime" prefill actions that
/// route through the chat composer (so the LLM picks cb_ssh_tail /
/// cb_ssh_exec through the write-gate).
struct ServersRail: View {
    @EnvironmentObject var chatStore: ChatStore
    @State private var hosts: [CswClient.SSHHostDTO] = []
    @State private var error: String?
    @State private var loading = false
    @State private var lastRefresh = Date.distantPast

    private let client = CswClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "server.rack").foregroundColor(.secondary).font(.system(size: 10))
                Text("Servers").font(.system(size: 10, weight: .heavy)).foregroundColor(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button {
                    Task { await refresh(force: true) }
                } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                .buttonStyle(.borderless)
            }
            content
        }
        .task { await refresh(force: false) }
    }

    @ViewBuilder
    private var content: some View {
        if let err = error {
            Text(err).font(.caption2).foregroundColor(.red)
        } else if hosts.isEmpty {
            Text("Chưa import host nào. Mở Diagnostics → Command Center.")
                .font(.caption2)
                .foregroundColor(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(hosts) { h in
                        ServerPill(host: h) { action in
                            performAction(action, on: h)
                        }
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    private func refresh(force: Bool) async {
        if !force && Date().timeIntervalSince(lastRefresh) < 30 { return }
        loading = true
        defer { loading = false }
        do {
            hosts = try await client.sshList()
            lastRefresh = Date()
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    private func performAction(_ action: ServerPillAction, on host: CswClient.SSHHostDTO) {
        let host = host.name
        switch action {
        case .askUptime:
            chatStore.sendCurrent(text: "Gọi cb_ssh_exec với host=\(host), cmd=uptime để check server.")
        case .tailJournal:
            chatStore.sendCurrent(text: "Gọi cb_ssh_tail với host=\(host), path=/var/log/syslog, lines=50, follow_seconds=0.")
        case .dockerPs:
            chatStore.sendCurrent(text: "Gọi cb_ssh_exec với host=\(host), cmd=`docker ps` để liệt kê containers.")
        }
    }
}

enum ServerPillAction {
    case askUptime
    case tailJournal
    case dockerPs
}

struct ServerPill: View {
    let host: CswClient.SSHHostDTO
    let onAction: (ServerPillAction) -> Void

    var body: some View {
        Menu {
            Button("uptime", action: { onAction(.askUptime) })
            Button("tail /var/log/syslog", action: { onAction(.tailJournal) })
            Button("docker ps", action: { onAction(.dockerPs) })
        } label: {
            HStack(spacing: 4) {
                Image(systemName: connectionIcon)
                    .foregroundColor(connectionColor)
                    .font(.system(size: 9))
                Text(host.name).font(.system(size: 11, design: .monospaced))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                Capsule().fill(Color.secondary.opacity(0.10))
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var connectionIcon: String {
        host.lastConnected != nil ? "circle.fill" : "circle"
    }
    private var connectionColor: Color {
        host.lastConnected != nil ? .green : .secondary
    }
}
