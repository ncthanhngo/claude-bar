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

    /// One watched service's up/down state (systemd unit or docker container).
    struct ServiceStatus: Decodable, Equatable, Identifiable {
        let name: String
        let state: String
        let active: Bool
        var id: String { name }
        /// "docker:api" → "api" for display; systemd units shown as-is.
        var shortName: String {
            name.hasPrefix("docker:") ? String(name.dropFirst("docker:".count)) : name
        }
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
        // Static hardware config. Optional/negative-sentinel so an older probe
        // that never set them still decodes.
        let cpuModel: String?
        let cpuCores: Int?
        let memTotalBytes: Int64?
        let rebootRequired: Bool?
        let services: [ServiceStatus]?
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

        /// Logical core count when known (> 0).
        var cores: Int? { (cpuCores ?? -1) > 0 ? cpuCores : nil }
        /// Total RAM in GiB (rounded), when known.
        var ramGiB: Int? {
            guard let b = memTotalBytes, b > 0 else { return nil }
            return Int((Double(b) / 1_073_741_824.0).rounded())
        }
        /// Trimmed CPU model when non-empty.
        var cpu: String? {
            guard let m = cpuModel?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else { return nil }
            return m
        }
        var hasSpecs: Bool { reachable && (cores != nil || ramGiB != nil || cpu != nil) }

        /// Load normalized to % of cores (100% = fully busy). Needs both a load
        /// reading and a known core count; nil otherwise so the UI falls back to
        /// the raw load number.
        var loadPct: Int? {
            guard hasLoad, let c = cores, c > 0 else { return nil }
            return Int((loadAvg1 / Double(c) * 100).rounded())
        }
        var needsReboot: Bool { reachable && (rebootRequired ?? false) }
        var watchedServices: [ServiceStatus] { reachable ? (services ?? []) : [] }
        /// Count of watched services currently down — drives the row badge.
        var servicesDown: Int { watchedServices.filter { !$0.active }.count }
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
