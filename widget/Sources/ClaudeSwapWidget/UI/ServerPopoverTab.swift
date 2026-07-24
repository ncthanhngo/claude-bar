import SwiftUI

/// Server tab of the popover: tracked SSH hosts with a "theo dõi" toggle. A
/// monitored host shows online/offline, disk (bar + sparkline), load/RAM/uptime,
/// an optional port check, latency, last-seen, a host-key-change warning, and a
/// one-click Connect. Uses the popover's system-color idiom (not the Daily palette).
struct ServerPopoverTab: View {
    @EnvironmentObject private var monitor: ServerMonitorStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            content
        }
        .onAppear {
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
            .buttonStyle(.plain).foregroundColor(.secondary).help("Kiểm tra lại ngay")
            Button { ServerSettingsWindowController.shared.present(monitor: monitor) } label: {
                Image(systemName: "gearshape").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundColor(.secondary).help("Quản lý server")
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        if monitor.hosts.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(monitor.hosts) { host in
                        ServerHostRow(
                            host: host,
                            health: monitor.health(for: host.name),
                            history: monitor.diskHistory[host.name] ?? [],
                            onToggle: { on in Task { await monitor.setMonitor(host: host.name, enabled: on) } },
                            onConnect: { monitor.connect(host) }
                        )
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack").font(.system(size: 26)).foregroundColor(.secondary)
            Text("Chưa có server nào").font(.system(size: 13, weight: .medium))
            Text("Thêm host bằng nút ⚙, rồi bật “Theo dõi”.")
                .font(.system(size: 11)).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
}

// MARK: - host row

private struct ServerHostRow: View {
    let host: CswClient.SSHHostDTO
    let health: CswClient.HostHealth?
    let history: [Int]
    let onToggle: (Bool) -> Void
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(host.displayName).font(.system(size: 12, weight: .semibold))
                        if health?.hostKeyChanged == true {
                            Image(systemName: "exclamationmark.shield.fill")
                                .font(.system(size: 10)).foregroundColor(.orange)
                                .help("Host key thay đổi — có thể bị giả mạo")
                        }
                    }
                    if let sub = subtitle {
                        Text(sub).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button(action: onConnect) { Image(systemName: "terminal").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundColor(.secondary).help("Mở Terminal SSH")
                Toggle("", isOn: Binding(get: { host.isMonitored }, set: onToggle))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).help("Theo dõi host này")
            }

            if host.isMonitored, let h = health {
                if h.hasDiskReading { diskRow(h) }
                if let stats = statsLine(h) {
                    Text(stats).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
                if !h.reachable {
                    Text("Mất kết nối\(h.error.map { " · \($0)" } ?? "")")
                        .font(.system(size: 10)).foregroundColor(.red).lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var dotColor: Color {
        guard host.isMonitored else { return Color.secondary.opacity(0.35) }
        guard let h = health else { return Color.secondary.opacity(0.6) }
        return h.reachable ? .green : .red
    }

    private var subtitle: String? {
        var bits: [String] = []
        if let h = health, h.reachable {
            if h.durationMs > 0 { bits.append("\(h.durationMs)ms") }
        }
        if let last = host.lastConnected { bits.append("thấy \(Self.relative(last))") }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private func diskRow(_ h: CswClient.HostHealth) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule().fill(diskColor(h.diskUsedPct))
                            .frame(width: max(4, geo.size.width * CGFloat(h.diskFraction)))
                    }
                }
                .frame(height: 6)
                if history.count >= 2 {
                    Sparkline(values: history).frame(width: 44, height: 12).foregroundColor(.secondary)
                }
            }
            Text("Disk \(h.diskUsedPct)% · \(h.diskPath)")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    /// "load 0.52 · RAM 40% · up 3d · :443 ✓" — only the fields that came back.
    private func statsLine(_ h: CswClient.HostHealth) -> String? {
        guard h.reachable else { return nil }
        var bits: [String] = []
        if h.hasLoad { bits.append(String(format: "load %.2f", h.loadAvg1)) }
        if h.hasMem { bits.append("RAM \(h.memUsedPct)%") }
        if h.hasUptime { bits.append("up \(Self.uptime(h.uptimeSecs))") }
        if let port = host.checkPort, port > 0, h.portOpen >= 0 {
            bits.append(":\(port) \(h.portOpen == 1 ? "✓" : "✗")")
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private func diskColor(_ pct: Int) -> Color {
        if pct >= AppSettings.shared.serverDiskCritPct { return .red }
        if pct >= AppSettings.shared.serverDiskWarnPct { return .orange }
        return .green
    }

    // MARK: formatting

    private static func uptime(_ secs: Int64) -> String {
        if secs >= 86_400 { return "\(secs / 86_400)d" }
        if secs >= 3_600 { return "\(secs / 3_600)h" }
        if secs >= 60 { return "\(secs / 60)m" }
        return "\(secs)s"
    }

    private static func relative(_ date: Date) -> String {
        let s = Int(max(0, Date().timeIntervalSince(date)))
        if s < 60 { return "vừa xong" }
        if s < 3_600 { return "\(s / 60)ph trước" }
        if s < 86_400 { return "\(s / 3_600)h trước" }
        return "\(s / 86_400)d trước"
    }
}

/// Tiny disk%-over-time line. Values are 0…100.
private struct Sparkline: View {
    let values: [Int]
    var body: some View {
        GeometryReader { geo in
            Path { p in
                guard values.count >= 2 else { return }
                let w = geo.size.width, h = geo.size.height
                let stepX = w / CGFloat(values.count - 1)
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = h - (CGFloat(max(0, min(100, v))) / 100.0) * h
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
        }
    }
}
