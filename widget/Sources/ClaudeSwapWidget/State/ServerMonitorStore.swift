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

    /// Trust a host's changed key (drops the stale known_hosts entry), clears
    /// the warning state, and re-probes.
    func trustHostKey(host: String) async {
        do {
            try await client.sshTrustKey(host: host)
            hostKeyAlerted.remove(host)
            await refreshNow()
        } catch { lastError = "\(error)" }
    }

    // MARK: - quiet hours (reuses the app's quiet-hours setting)

    private func isQuietNow() -> Bool {
        guard let s = minutesOfDay(settings.quietHoursStart),
              let e = minutesOfDay(settings.quietHoursEnd), s != e else { return false }
        let cal = Calendar.current
        let now = cal.component(.hour, from: Date()) * 60 + cal.component(.minute, from: Date())
        return s < e ? (now >= s && now < e) : (now >= s || now < e)
    }

    private func minutesOfDay(_ hhmm: String) -> Int? {
        let p = hhmm.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return h * 60 + m
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
                 jump: String, checkPort: Int, services: String) async {
        do {
            try await client.sshAdd(name: name, host: host, port: port, user: user,
                                    identity: identity, jump: jump, display: display,
                                    diskPath: diskPath, checkPort: checkPort, services: services)
            await loadHosts()
        } catch { lastError = "\(error)" }
    }

    /// Edit an existing host. `displayName` empty reverts to the identity name;
    /// `identity` empty drops the key. Re-probes if the host is monitored so
    /// new credentials take effect immediately.
    func updateHost(name: String, displayName: String, host: String,
                    user: String, port: Int, identity: String, diskPath: String,
                    jump: String, checkPort: Int, services: String) async {
        do {
            try await client.sshUpdate(name: name, displayName: displayName, host: host,
                                       user: user, port: port, identity: identity,
                                       diskPath: diskPath, jump: jump, checkPort: checkPort,
                                       services: services)
            await loadHosts()
            if hosts.first(where: { $0.name == name })?.isMonitored == true {
                await refreshNow()
            }
        } catch { lastError = "\(error)" }
    }

    // MARK: - on-demand actions (reuse `ssh exec`)

    /// Run a read-only command on a host and return its combined output. Used by
    /// the quick-action viewers (top processes, pending updates). Never throws —
    /// failures come back as a readable string.
    private func runAction(host: String, command: String, timeout: Int = 45) async -> String {
        do {
            let r = try await client.sshExec(host: host, command: command, timeoutSeconds: timeout)
            let out = r.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? "(không có output, exit \(r.exitCode))" : out
        } catch {
            return "Lỗi: \(error)"
        }
    }

    /// Top processes by CPU, then memory.
    func topProcesses(host: String) async -> String {
        await runAction(host: host, command:
            "LC_ALL=C ps -eo pid,pcpu,pmem,rss,comm --sort=-pcpu 2>/dev/null | head -n 15", timeout: 45)
    }

    /// Count of pending package updates (apt or dnf). Slower — on demand only.
    func pendingUpdates(host: String) async -> String {
        await runAction(host: host, command:
            "if command -v apt-get >/dev/null 2>&1; then " +
            "n=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst'); echo \"$n gói cần cập nhật (apt)\"; " +
            "apt-get -s upgrade 2>/dev/null | grep '^Inst' | awk '{print $2}' | head -n 30; " +
            "elif command -v dnf >/dev/null 2>&1; then " +
            "dnf -q check-update 2>/dev/null | grep -cE '^[a-zA-Z0-9]' | sed 's/$/ gói cần cập nhật (dnf)/'; " +
            "else echo 'Không nhận diện được trình quản lý gói'; fi", timeout: 90)
    }

    /// Last 200 log lines for a watched service — journalctl for a systemd unit,
    /// `docker logs` for a "docker:<name>" token.
    func serviceLog(host: String, service: String) async -> String {
        let cmd: String
        if service.hasPrefix("docker:") {
            let name = String(service.dropFirst("docker:".count))
            cmd = "docker logs --tail 200 \(shArg(name)) 2>&1"
        } else {
            cmd = "journalctl -u \(shArg(service)) --no-pager -n 200 2>&1 || " +
                  "sudo -n journalctl -u \(shArg(service)) --no-pager -n 200 2>&1"
        }
        return await runAction(host: host, command: cmd)
    }

    /// Recent system journal (last 200 lines).
    func systemLog(host: String) async -> String {
        await runAction(host: host, command:
            "journalctl --no-pager -n 200 2>&1 || sudo -n journalctl --no-pager -n 200 2>&1")
    }

    /// Journal from the PREVIOUS boot — the post-mortem view after a crash/reboot
    /// (needs persistent journald, default on most distros).
    func previousBootLog(host: String) async -> String {
        await runAction(host: host, command:
            "journalctl -b -1 --no-pager -n 300 2>&1 || " +
            "sudo -n journalctl -b -1 --no-pager -n 300 2>&1 || " +
            "echo 'Không có log boot trước (journald không lưu trữ liên tục?)'")
    }

    /// Kernel ring buffer — catches OOM-killer, hardware faults, filesystem errors.
    func kernelLog(host: String) async -> String {
        await runAction(host: host, command:
            "dmesg -T 2>/dev/null | tail -n 200 || sudo -n dmesg -T 2>/dev/null | tail -n 200 || " +
            "echo 'Không đọc được dmesg (cần quyền root)'")
    }

    /// Restart a watched service (systemd unit or "docker:<name>"). Mutating —
    /// callers must confirm first. Re-probes so the status pill updates.
    func restartService(host: String, service: String) async -> String {
        let cmd: String
        if service.hasPrefix("docker:") {
            let name = String(service.dropFirst("docker:".count))
            cmd = "docker restart \(shArg(name)) 2>&1"
        } else {
            cmd = "sudo -n systemctl restart \(shArg(service)) 2>&1 || systemctl restart \(shArg(service)) 2>&1"
        }
        let out = await runAction(host: host, command: cmd)
        await refreshNow()
        return out
    }

    /// Minimal single-quote shell escaping for a service name echoed into a
    /// command string. Service tokens are user config, so quote defensively.
    private func shArg(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

    /// Export every tracked host to an encrypted `.cbssh` file at `path`,
    /// protected by `passphrase` (age scrypt). Metadata only — private keys and
    /// SSH passwords never leave this Mac. Returns true on success.
    @discardableResult
    func exportBundle(toPath path: String, passphrase: String) async -> Bool {
        do {
            try await client.sshExportBundle(toPath: path, passphrase: passphrase)
            lastError = nil
            return true
        } catch {
            lastError = "\(error)"
            return false
        }
    }

    /// Import hosts from a `.cbssh` file. `merge` true adds/updates alongside
    /// existing hosts (default, non-destructive); false replaces the whole list.
    /// Reloads the roster + re-probes on success. Returns true on success.
    @discardableResult
    func importBundle(fromPath path: String, passphrase: String, merge: Bool) async -> Bool {
        do {
            try await client.sshImportBundle(fromPath: path, passphrase: passphrase, merge: merge)
            await loadHosts()
            await refreshNow()
            lastError = nil
            return true
        } catch {
            lastError = "\(error)"
            return false
        }
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
            if diskAlerted.contains(h.name) { return }
            // During quiet hours defer (don't mark alerted) so it fires once the
            // window ends if still critical. Disconnect/host-key stay unmuted.
            if isQuietNow() { return }
            diskAlerted.insert(h.name)
            notify(title: "Disk sắp đầy",
                   body: "\(h.name): \(h.diskUsedPct)% ở \(h.diskPath).",
                   id: "csw.server.disk.\(h.name)")
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
