import SwiftUI

/// Which log snapshot a quick-action requests.
enum ServerLogKind {
    case service(String)   // journalctl -u / docker logs
    case system            // recent system journal
    case previousBoot      // journalctl -b -1 (post-crash)
    case kernel            // dmesg
}

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
                    ForEach(sortedHosts) { host in
                        ServerHostRow(
                            host: host,
                            health: monitor.health(for: host.name),
                            history: monitor.diskHistory[host.name] ?? [],
                            onToggle: { on in Task { await monitor.setMonitor(host: host.name, enabled: on) } },
                            onConnect: { monitor.connect(host) },
                            onTrustKey: { Task { await monitor.trustHostKey(host: host.name) } },
                            onTopProcesses: {
                                ServerActionWindow.present(title: "Tiến trình · \(host.displayName)") {
                                    await monitor.topProcesses(host: host.name)
                                }
                            },
                            onUpdates: {
                                ServerActionWindow.present(title: "Cập nhật · \(host.displayName)") {
                                    await monitor.pendingUpdates(host: host.name)
                                }
                            },
                            onRestart: { svc in restartService(host: host, service: svc) },
                            onLog: { kind in openLog(host: host, kind: kind) }
                        )
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    /// Problem hosts (offline, then disk-critical) float to the top; the rest
    /// stay alphabetical.
    private var sortedHosts: [CswClient.SSHHostDTO] {
        monitor.hosts.sorted { a, b in
            let ra = problemRank(a), rb = problemRank(b)
            if ra != rb { return ra > rb }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    private func problemRank(_ h: CswClient.SSHHostDTO) -> Int {
        guard h.isMonitored, let hh = monitor.health(for: h.name) else { return 0 }
        if !hh.reachable { return 2 }
        if hh.hasDiskReading && hh.diskUsedPct >= AppSettings.shared.serverDiskCritPct { return 1 }
        return 0
    }

    /// Open a log snapshot in an output window. Maps the requested kind to a
    /// title + the matching store command.
    private func openLog(host: CswClient.SSHHostDTO, kind: ServerLogKind) {
        let name = host.displayName
        switch kind {
        case .service(let svc):
            ServerActionWindow.present(title: "Log \(svc) · \(name)") {
                await monitor.serviceLog(host: host.name, service: svc)
            }
        case .system:
            ServerActionWindow.present(title: "Log hệ thống · \(name)") {
                await monitor.systemLog(host: host.name)
            }
        case .previousBoot:
            ServerActionWindow.present(title: "Log sau crash (boot trước) · \(name)") {
                await monitor.previousBootLog(host: host.name)
            }
        case .kernel:
            ServerActionWindow.present(title: "Kernel (dmesg) · \(name)") {
                await monitor.kernelLog(host: host.name)
            }
        }
    }

    /// Confirm (raised above the popover), then restart the service and show the
    /// result in an output window.
    private func restartService(host: CswClient.SSHHostDTO, service: String) {
        guard ServerActionWindow.confirm(
            title: "Khởi động lại \(service)?",
            message: "Chạy trên \(host.displayName). Dịch vụ sẽ gián đoạn trong giây lát.",
            confirmTitle: "Khởi động lại"
        ) else { return }
        ServerActionWindow.present(title: "Restart \(service) · \(host.displayName)") {
            await monitor.restartService(host: host.name, service: service)
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
    let onTrustKey: () -> Void
    let onTopProcesses: () -> Void
    let onUpdates: () -> Void
    let onRestart: (String) -> Void
    let onLog: (ServerLogKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            headerRow

            if host.isMonitored, let h = health, h.reachable {
                if h.hasSpecs { specsRow(h) }
                metricChips(h)
                if h.hasDiskReading { diskRow(h) }
                if !h.watchedServices.isEmpty { servicesRow(h) }
            } else if host.isMonitored, let h = health, !h.reachable {
                Text("Mất kết nối\(h.error.map { " · \($0)" } ?? "")")
                    .font(.system(size: 10)).foregroundColor(.red).lineLimit(2)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    // MARK: header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(host.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    badges
                }
                if let sub = subtitle {
                    Text(sub).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if host.isMonitored, health?.reachable == true { actionsMenu }
            Button(action: onConnect) { Image(systemName: "terminal").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundColor(.secondary).help("Mở Terminal SSH")
            Toggle("", isOn: Binding(get: { host.isMonitored }, set: onToggle))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini).help("Theo dõi host này")
        }
    }

    /// Compact status badges next to the name: host-key change, reboot needed,
    /// and a count of down services — the at-a-glance "needs attention" signals.
    @ViewBuilder
    private var badges: some View {
        if health?.hostKeyChanged == true {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 10)).foregroundColor(.orange)
                .help("Host key thay đổi — có thể bị giả mạo")
            Button("Tin khoá", action: onTrustKey)
                .buttonStyle(.plain).font(.system(size: 9, weight: .semibold)).foregroundColor(.orange)
                .help("Chấp nhận khoá mới (xoá known_hosts cũ)")
        }
        if health?.needsReboot == true {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 10)).foregroundColor(.orange)
                .help("Cần khởi động lại máy (kernel/thư viện đã cập nhật)")
        }
        if let down = health?.servicesDown, down > 0 {
            Text("\(down) dịch vụ ✕")
                .font(.system(size: 9, weight: .semibold)).foregroundColor(.red)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.red.opacity(0.15)))
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button { onTopProcesses() } label: { Label("Tiến trình đang chạy", systemImage: "chart.bar") }
            Button { onUpdates() } label: { Label("Kiểm tra cập nhật", systemImage: "shippingbox") }
            Divider()
            Menu {
                Button { onLog(.system) } label: { Label("Log hệ thống gần đây", systemImage: "list.bullet.rectangle") }
                Button { onLog(.previousBoot) } label: { Label("Log sau crash (boot trước)", systemImage: "exclamationmark.arrow.circlepath") }
                Button { onLog(.kernel) } label: { Label("Kernel (dmesg)", systemImage: "cpu") }
            } label: { Label("Xem log", systemImage: "doc.text.magnifyingglass") }
            if !(health?.watchedServices.isEmpty ?? true) {
                Divider()
                ForEach(health?.watchedServices ?? []) { svc in
                    Menu {
                        Button { onLog(.service(svc.name)) } label: { Label("Xem log", systemImage: "doc.text") }
                        Button { onRestart(svc.name) } label: { Label("Restart", systemImage: "arrow.clockwise") }
                    } label: { Label(svc.shortName, systemImage: svc.active ? "circle.fill" : "circle") }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 12))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundColor(.secondary).help("Thao tác nhanh")
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

    /// Static hardware config: "8 cores · 16 GB" with the CPU model beneath.
    /// The model tail-truncates so a long "Intel(R) Xeon(R)…" never wraps.
    @ViewBuilder
    private func specsRow(_ h: CswClient.HostHealth) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            let head = [h.cores.map { "\($0) core\($0 == 1 ? "" : "s")" },
                        h.ramGiB.map { "\($0) GB RAM" }].compactMap { $0 }.joined(separator: " · ")
            HStack(spacing: 5) {
                Image(systemName: "cpu").font(.system(size: 9)).foregroundColor(.secondary)
                if !head.isEmpty {
                    Text(head).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                }
                if let cpu = h.cpu {
                    Text(cpu).font(.system(size: 10)).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
        }
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
            if h.allMounts.count > 1 {
                // Per-mount breakdown when several are watched (the chip only
                // shows the worst one).
                ForEach(h.allMounts) { m in
                    HStack(spacing: 6) {
                        Text(m.path.isEmpty ? "?" : m.path)
                            .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
                        Spacer()
                        Text("\(m.usedPct)%").font(.system(size: 9, weight: .medium)).foregroundColor(diskColor(m.usedPct))
                    }
                }
            } else {
                // Single mount: the chip carries the %, so just name the path.
                Text(h.diskPath).font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary).lineLimit(1)
            }
        }
    }

    // MARK: metric chips + services

    /// One scannable row of color chips: CPU (load normalized to cores), RAM,
    /// Disk (severity-tinted), plus neutral uptime and a green/red port chip.
    /// Horizontally scrollable so a wide set never breaks the row.
    @ViewBuilder
    private func metricChips(_ h: CswClient.HostHealth) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let cpu = h.loadPct {
                    MetricChip(label: "CPU", value: "\(cpu)%", color: loadColor(cpu))
                } else if h.hasLoad {
                    MetricChip(label: "load", value: String(format: "%.2f", h.loadAvg1), color: neutralChip)
                }
                if h.hasMem {
                    MetricChip(label: "RAM", value: "\(h.memUsedPct)%", color: loadColor(h.memUsedPct))
                }
                if h.hasDiskReading {
                    MetricChip(label: "Disk", value: "\(h.diskUsedPct)%", color: diskColor(h.diskUsedPct))
                }
                if h.hasUptime {
                    MetricChip(label: "up", value: Self.uptime(h.uptimeSecs), color: neutralChip)
                }
                if let port = host.checkPort, port > 0, h.portOpen >= 0 {
                    MetricChip(label: ":\(port)", value: h.portOpen == 1 ? "✓" : "✗",
                               color: h.portOpen == 1 ? .green : .red)
                }
            }
        }
    }

    /// Neutral fill for non-severity chips (uptime / raw load) so they read as
    /// info, not alarm. Adapts to light/dark.
    private var neutralChip: Color { Color.gray.opacity(0.7) }

    /// A pill per watched service, green dot = up, red = down. Horizontally
    /// scrollable so a long service list never breaks the row layout.
    private func servicesRow(_ h: CswClient.HostHealth) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(h.watchedServices) { s in
                    HStack(spacing: 3) {
                        Circle().fill(s.active ? Color.green : .red).frame(width: 6, height: 6)
                        Text(s.shortName).font(.system(size: 10, weight: .medium))
                            .foregroundColor(s.active ? .primary.opacity(0.75) : .red)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .help(s.active ? "\(s.name): \(s.state)" : "\(s.name): \(s.state) — dừng")
                }
            }
        }
    }

    /// Green < 70%, amber < 90%, red — shared by the CPU and RAM chips.
    private func loadColor(_ pct: Int) -> Color {
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .green
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

/// A small labeled metric pill: "CPU 42%". The pill is filled with the severity
/// color and the text is white, so the whole chip — not just the number —
/// carries the traffic-light signal and stays high-contrast.
private struct MetricChip: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.85))
            Text(value).font(.system(size: 10, weight: .bold)).foregroundColor(.white)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color))
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
