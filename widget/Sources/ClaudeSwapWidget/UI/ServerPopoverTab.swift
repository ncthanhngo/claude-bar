import SwiftUI

/// Server tab of the popover: the list of tracked SSH hosts, each with a
/// "theo dõi" toggle. Monitored hosts show an online/offline dot and — when
/// reachable — a disk-usage bar (orange ≥85%, coral ≥90%). Disconnects also
/// raise a notification from `ServerMonitorStore`; this view is the at-a-glance
/// surface. Uses the popover's system-color idiom (not the Daily palette).
struct ServerPopoverTab: View {
    @EnvironmentObject private var monitor: ServerMonitorStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            content
        }
        .onAppear {
            // Cheap local host-list read + a probe so the tab shows fresh
            // numbers the moment it's opened, without waiting for the 5-min tick.
            Task {
                await monitor.loadHosts()
                await monitor.refreshNow()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Servers")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary.opacity(0.78))
            if monitor.isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            Spacer()
            Button { Task { await monitor.refreshNow() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Kiểm tra lại ngay")
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        if monitor.hosts.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(monitor.hosts) { host in
                        ServerHostRow(host: host, health: monitor.health(for: host.name)) { on in
                            Task { await monitor.setMonitor(host: host.name, enabled: on) }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 26))
                .foregroundColor(.secondary)
            Text("Chưa có server nào")
                .font(.system(size: 13, weight: .medium))
            Text("Thêm host ở Daily → Netbird → SSH, rồi bật “Theo dõi”.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// One host card: status dot + name + monitor toggle, plus a disk bar or an
/// offline line when monitored.
private struct ServerHostRow: View {
    let host: CswClient.SSHHostDTO
    let health: CswClient.HostHealth?
    let onToggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.name).font(.system(size: 12, weight: .semibold))
                    if let sub = subtitle {
                        Text(sub).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { host.isMonitored }, set: onToggle))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Theo dõi host này")
            }

            if host.isMonitored, let h = health {
                if h.hasDiskReading {
                    diskBar(h)
                } else if !h.reachable {
                    Text("Mất kết nối\(h.error.map { " · \($0)" } ?? "")")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var dotColor: Color {
        guard host.isMonitored else { return Color.secondary.opacity(0.35) }
        guard let h = health else { return Color.secondary.opacity(0.6) } // probing
        return h.reachable ? .green : .red
    }

    private var subtitle: String? {
        if host.isMonitored, let h = health, h.hasDiskReading { return nil } // disk bar carries detail
        if let hn = host.hostName, !hn.isEmpty {
            if let u = host.user, !u.isEmpty { return "\(u)@\(hn)" }
            return hn
        }
        return nil
    }

    private func diskBar(_ h: CswClient.HostHealth) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(diskColor(h.diskUsedPct))
                        .frame(width: max(4, geo.size.width * CGFloat(h.diskFraction)))
                }
            }
            .frame(height: 6)
            Text("Disk \(h.diskUsedPct)% · \(h.diskPath)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private func diskColor(_ pct: Int) -> Color {
        if pct >= ServerMonitorStore.diskCritPct { return .red }
        if pct >= ServerMonitorStore.diskWarnPct { return .orange }
        return .green
    }
}
