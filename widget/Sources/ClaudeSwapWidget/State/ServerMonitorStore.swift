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

    private let client: CswClient
    private var pollTask: Task<Void, Never>?

    /// Fixed 5-min cadence (mirrors BriefingCoordinator). SSH probes are cheap
    /// but shouldn't hammer; not adaptive / not user-configurable yet (YAGNI).
    private let pollIntervalNanos: UInt64 = 300 * 1_000_000_000

    /// Consecutive probe failures before a host is declared down — smooths a
    /// single transient failure so we don't cry wolf.
    private let downThreshold = 2

    // Per-host edge state, keyed by host name.
    private var failStreak: [String: Int] = [:]
    private var reportedDown: Set<String> = []

    init(client: CswClient = CswClient()) {
        self.client = client
    }

    /// Disk warn / crit thresholds (percent). Crit turns the bar coral.
    static let diskWarnPct = 85
    static let diskCritPct = 90

    // MARK: - lifecycle (driven by BackgroundWorkController)

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.loadHosts()
            await self?.refreshNow()
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.pollIntervalNanos)
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
            for h in results { evaluateEdge(h) }
        } catch {
            lastError = "\(error)"
        }
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
                failStreak[host] = nil
                reportedDown.remove(host)
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
                 port: Int, identity: String, diskPath: String) async {
        do {
            try await client.sshAdd(name: name, host: host, port: port, user: user,
                                    identity: identity, display: display, diskPath: diskPath)
            await loadHosts()
        } catch { lastError = "\(error)" }
    }

    /// Edit an existing host. `displayName` empty reverts to the identity name;
    /// `identity` empty drops the key. Re-probes if the host is monitored so
    /// new credentials take effect immediately.
    func updateHost(name: String, displayName: String, host: String,
                    user: String, port: Int, identity: String, diskPath: String) async {
        do {
            try await client.sshUpdate(name: name, displayName: displayName, host: host,
                                       user: user, port: port, identity: identity, diskPath: diskPath)
            await loadHosts()
            if hosts.first(where: { $0.name == name })?.isMonitored == true {
                await refreshNow()
            }
        } catch { lastError = "\(error)" }
    }

    /// Delete a host and clear any monitor state for it.
    func removeHost(name: String) async {
        do {
            try await client.sshRemove(name: name)
            failStreak[name] = nil
            reportedDown.remove(name)
            healths.removeAll { $0.name == name }
            await loadHosts()
        } catch { lastError = "\(error)" }
    }

    // MARK: - edge detection → notifications (disconnect only)

    private func evaluateEdge(_ h: CswClient.HostHealth) {
        if h.reachable {
            failStreak[h.name] = 0
            if reportedDown.remove(h.name) != nil {
                notify(title: "Server đã kết nối lại",
                       body: "\(h.name) phản hồi trở lại.",
                       id: "csw.server.up.\(h.name)")
            }
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

    private func notify(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(req) }
    }
}
