import Foundation

/// Server health monitor RPCs — `csw ssh health` (probe monitored hosts) and
/// `csw ssh monitor` (toggle the opt-in flag per host). Backs the popover
/// Server tab. Reachability + disk% come from one `df -P` per host, run over
/// the same SSH host store the backup / assistant tools use.
extension CswClient {

    /// One monitored host's snapshot. `diskUsedPct` is 0–100 only when
    /// `reachable` and the df output parsed; -1 means "no reading".
    struct DiskMount: Decodable, Equatable, Identifiable {
        let path: String
        let usedPct: Int
        var id: String { path }
    }

    struct HostHealth: Decodable, Identifiable, Equatable {
        let name: String
        let reachable: Bool
        let diskUsedPct: Int
        let diskPath: String
        // Optional so a Go nil slice (JSON null) still decodes — see the
        // go-nil-slice memory. Use `allMounts` for a non-nil view.
        let mounts: [DiskMount]?
        let loadAvg1: Double
        let memUsedPct: Int
        let uptimeSecs: Int64
        let portOpen: Int          // -1 unknown, 0 closed, 1 open
        let hostKeyChanged: Bool
        let exitCode: Int
        let durationMs: Int64
        let error: String?
        let checkedAt: Date?

        var id: String { name }

        /// True when we have an actual disk percentage to render.
        var hasDiskReading: Bool { reachable && diskUsedPct >= 0 }
        /// 0…1 fill for the usage bar; 0 when there's no reading.
        var diskFraction: Double { hasDiskReading ? Double(diskUsedPct) / 100.0 : 0 }
        var hasLoad: Bool { reachable && loadAvg1 >= 0 }
        var hasMem: Bool { reachable && memUsedPct >= 0 }
        var hasUptime: Bool { reachable && uptimeSecs >= 0 }
        var allMounts: [DiskMount] { mounts ?? [] }
    }

    /// Probe every host with `monitor=true` (one `df` each). Never partial —
    /// an unreachable host comes back as `reachable=false`.
    func hostHealth() async throws -> [HostHealth] {
        try await self.run(["ssh", "health"], decode: [HostHealth].self)
    }

    /// Toggle the health probe for a host; optionally set the disk path. The
    /// bool must be `--enabled=<v>` (Go's flag package won't take a separate
    /// arg for a bool).
    func sshSetMonitor(host: String, enabled: Bool, diskPath: String? = nil) async throws {
        var args = ["ssh", "monitor", "--host", host, "--enabled=\(enabled)"]
        if let diskPath, !diskPath.isEmpty { args += ["--disk-path", diskPath] }
        _ = try await self.runRaw(args)
    }
}
