import Foundation
import UserNotifications

/// App-level monitor for opted-in SSH hosts. Polls `csw ssh health` (one
/// `df -P` per monitored host) on a fixed cadence WHILE THE APP IS OPEN,
/// feeds the popover Server tab, and fires a macOS notification on the
/// connected→disconnected edge. Disk usage is display-only (shown in the tab,
/// no notification) per the product intent: "disconnect → noti, disk → view".
///
/// Registered with `BackgroundWorkController` so the Settings dormant toggle
/// pauses this loop with everything else. Because it's a menu-bar app the
/// monitor only runs while the app is open — not a 24/7 server-side watch.
@MainActor
final class ServerMonitorStore: ObservableObject {
    /// Every tracked host (monitored or not) — backs the toggle list.
    @Published private(set) var hosts: [CswClient.SSHHostDTO] = []
    /// Latest probe result per monitored host.
    @Published private(set) var healths: [CswClient.HostHealth] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    /// Recent disk% samples per host (oldest→newest, capped) for the sparkline.
    @Published private(set) var diskHistory: [String: [Int]] = [:]

    private let client: CswClient
    private var pollTask: Task<Void, Never>?
    private let historyCap = 30

    /// Consecutive probe failures before a host is declared down — smooths a
    /// single transient failure so we don't cry wolf.
    private let downThreshold = 2

    // Per-host edge state, keyed by host name.
    private var failStreak: [String: Int] = [:]
    private var reportedDown: Set<String> = []
    private var diskAlerted: Set<String> = []       // crossed crit, awaiting drop below warn
    private var hostKeyAlerted: Set<String> = []

    private let historyDefaultsKey = "serverDiskHistory"

    init(client: CswClient = CswClient()) {
        self.client = client
        loadHistory()
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: [Int]].self, from: data)
        else { return }
        diskHistory = decoded
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(diskHistory) {
            UserDefaults.standard.set(data, forKey: historyDefaultsKey)
        }
    }

    private var settings: AppSettings { AppSettings.shared }
    var diskWarnPct: Int { settings.serverDiskWarnPct }
    var diskCritPct: Int { settings.serverDiskCritPct }

    /// True when any monitored host is currently down — used to tighten the
    /// poll cadence (adaptive backoff) so a recovery is noticed sooner.
    var anyDown: Bool { healths.contains { !$0.reachable } }

    /// Next sleep, in nanoseconds. Base comes from settings; when a host is
    /// down we re-check every minute until it recovers.
    private func nextIntervalNanos() -> UInt64 {
        let baseMin = max(1, settings.serverPollIntervalMinutes)
        let secs = anyDown ? min(60, baseMin * 60) : baseMin * 60
        return UInt64(secs) * 1_000_000_000
    }

    // MARK: - lifecycle (driven by BackgroundWorkController)

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.loadHosts()
            await self?.refreshNow()
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.nextIntervalNanos())
                if Task.isCancelled { return }
                await self.refreshNow()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - data

    /// Reload the tracked-host list (cheap local JSON read) for the toggle UI.
    func loadHosts() async {
        do { hosts = try await client.sshList() }
        catch { lastError = "\(error)" }
    }

    /// One probe cycle across all monitored hosts.
    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let results = try await client.hostHealth()
            healths = results
            lastError = nil
            for h in results {
                evaluateEdge(h)
                if h.hasDiskReading { appendDiskSample(host: h.name, pct: h.diskUsedPct) }
            }
        } catch {
            lastError = "\(error)"
        }
    }

    private func appendDiskSample(host: String, pct: Int) {
        var samples = diskHistory[host] ?? []
        samples.append(pct)
        if samples.count > historyCap { samples.removeFirst(samples.count - historyCap) }
        diskHistory[host] = samples
        saveHistory()
    }

    /// Open an interactive SSH session to the host in Terminal.app.
    func connect(_ host: CswClient.SSHHostDTO) {
        SSHTerminalLauncher.open(host)
    }

    /// Turn the health probe on/off for a host, then reconcile local state.
    func setMonitor(host: String, enabled: Bool) async {
        do {
            try await client.sshSetMonitor(host: host, enabled: enabled)
            await loadHosts()
            if enabled {
                await refreshNow()
            } else {
                // Drop stale edge + health state so the row goes quiet.
                clearHostState(host)
                healths.removeAll { $0.name == host }
            }
        } catch {
            lastError = "\(error)"
        }
    }

    /// Health snapshot for a host name, if monitored + probed.
    func health(for name: String) -> CswClient.HostHealth? {
        healths.first { $0.name == name }
    }

    // MARK: - host management (from the Server settings sheet)

    /// Register a new host with real credentials (key-based auth).
    func addHost(name: String, display: String, host: String, user: String,
                 port: Int, identity: String, diskPath: String,
                 jump: String, checkPort: Int) async {
        do {
            try await client.sshAdd(name: name, host: host, port: port, user: user,
                                    identity: identity, jump: jump, display: display,
                                    diskPath: diskPath, checkPort: checkPort)
            await loadHosts()
        } catch { lastError = "\(error)" }
    }

    /// Edit an existing host. `displayName` empty reverts to the identity name;
    /// `identity` empty drops the key. Re-probes if the host is monitored so
    /// new credentials take effect immediately.
    func updateHost(name: String, displayName: String, host: String,
                    user: String, port: Int, identity: String, diskPath: String,
                    jump: String, checkPort: Int) async {
        do {
            try await client.sshUpdate(name: name, displayName: displayName, host: host,
                                       user: user, port: port, identity: identity,
                                       diskPath: diskPath, jump: jump, checkPort: checkPort)
            await loadHosts()
            if hosts.first(where: { $0.name == name })?.isMonitored == true {
                await refreshNow()
            }
        } catch { lastError = "\(error)" }
    }

    /// Store or clear a host's SSH password (empty = clear). Re-probes if the
    /// host is monitored so the new auth takes effect immediately.
    func setPassword(host: String, password: String) async {
        do {
            try await client.sshSetPassword(host: host, password: password)
            await loadHosts()
            if hosts.first(where: { $0.name == host })?.isMonitored == true {
                await refreshNow()
            }
        } catch { lastError = "\(error)" }
    }

    /// Delete a host and clear any monitor state for it.
    func removeHost(name: String) async {
        do {
            try await client.sshRemove(name: name)
            clearHostState(name)
            healths.removeAll { $0.name == name }
            await loadHosts()
        } catch { lastError = "\(error)" }
    }

    private func clearHostState(_ name: String) {
        failStreak[name] = nil
        reportedDown.remove(name)
        diskAlerted.remove(name)
        hostKeyAlerted.remove(name)
        diskHistory[name] = nil
        saveHistory()
    }

    // MARK: - edge detection → notifications (disconnect only)

    private func evaluateEdge(_ h: CswClient.HostHealth) {
        // Host-key change is a security signal — surface it regardless of
        // reachability, once per occurrence.
        if h.hostKeyChanged {
            if hostKeyAlerted.insert(h.name).inserted {
                notify(title: "⚠ Khoá máy chủ thay đổi",
                       body: "\(h.name): host key khác known_hosts — có thể bị giả mạo. Kiểm tra trước khi kết nối.",
                       id: "csw.server.hostkey.\(h.name)")
            }
        } else {
            hostKeyAlerted.remove(h.name)
        }

        if h.reachable {
            failStreak[h.name] = 0
            if reportedDown.remove(h.name) != nil {
                notify(title: "Server đã kết nối lại",
                       body: "\(h.name) phản hồi trở lại.",
                       id: "csw.server.up.\(h.name)")
            }
            evaluateDisk(h)
            return
        }
        let streak = (failStreak[h.name] ?? 0) + 1
        failStreak[h.name] = streak
        if streak >= downThreshold && !reportedDown.contains(h.name) {
            reportedDown.insert(h.name)
            let detail = (h.error?.isEmpty == false) ? " (\(h.error!))" : ""
            notify(title: "Server mất kết nối",
                   body: "\(h.name) không phản hồi.\(detail)",
                   id: "csw.server.down.\(h.name)")
        }
    }

    /// Disk alert (opt-in). Fires once when crossing the crit threshold; only
    /// re-arms after the host drops back below the warn threshold (hysteresis),
    /// so a host hovering at the line doesn't notify every cycle.
    private func evaluateDisk(_ h: CswClient.HostHealth) {
        guard settings.serverDiskAlertsEnabled, h.hasDiskReading else { return }
        if h.diskUsedPct >= diskCritPct {
            if diskAlerted.insert(h.name).inserted {
                notify(title: "Disk sắp đầy",
                       body: "\(h.name): \(h.diskUsedPct)% ở \(h.diskPath).",
                       id: "csw.server.disk.\(h.name)")
            }
        } else if h.diskUsedPct < diskWarnPct {
            diskAlerted.remove(h.name)
        }
    }

    private func notify(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(req) }
    }
}
