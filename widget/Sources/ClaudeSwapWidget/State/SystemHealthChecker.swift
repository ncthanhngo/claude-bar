import Foundation

/// One health-check row: a name, a human-readable value, and a status.
struct HealthCheck: Identifiable, Hashable {
    enum Status: Hashable { case good, warn, bad }
    var id: String { name }
    let name: String
    let detail: String
    let status: Status
}

/// Read-only system health snapshot (disk · RAM · swap · SIP · FileVault ·
/// Gatekeeper · SMART · macOS · uptime) with a 0–100 score. Status-only shell
/// calls, no sudo, nothing is changed.
@MainActor
final class SystemHealthChecker: ObservableObject {
    @Published private(set) var checks: [HealthCheck] = []
    @Published private(set) var score = 0
    @Published private(set) var isRunning = false

    func run() {
        guard !isRunning else { return }
        isRunning = true
        Task {
            let result = await Task.detached { SystemHealthChecker.gather() }.value
            self.checks = result
            self.score = SystemHealthChecker.scoreOf(result)
            self.isRunning = false
        }
    }

    nonisolated static func scoreOf(_ checks: [HealthCheck]) -> Int {
        let scored = checks.filter { $0.status != .good || $0.name.contains("đĩa") || $0.name.contains("Swap")
            || $0.name.contains("SIP") || $0.name.contains("FileVault") || $0.name.contains("Gatekeeper") || $0.name.contains("SMART") }
        let pool = scored.isEmpty ? checks : scored
        guard !pool.isEmpty else { return 100 }
        let per = 100.0 / Double(pool.count)
        var s = 0.0
        for c in pool {
            switch c.status {
            case .good: s += per
            case .warn: s += per * 0.5
            case .bad: break
            }
        }
        return Int(s.rounded())
    }

    nonisolated static func gather() -> [HealthCheck] {
        var out: [HealthCheck] = []

        if let v = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            let free = Int64(v.volumeAvailableCapacityForImportantUsage ?? 0)
            let total = Int64(v.volumeTotalCapacity ?? 1)
            let pct = total > 0 ? Double(free) / Double(total) * 100 : 0
            let status: HealthCheck.Status = pct > 15 ? .good : (pct > 7 ? .warn : .bad)
            out.append(HealthCheck(name: "Dung lượng đĩa",
                detail: "\(ByteFormat.string(free)) trống / \(ByteFormat.string(total)) (\(Int(pct))%)", status: status))
        }

        let ram = Int64(ProcessInfo.processInfo.physicalMemory)
        out.append(HealthCheck(name: "RAM", detail: ByteFormat.string(ram), status: .good))

        let swap = Shell.sh("sysctl -n vm.swapusage")
        if let used = swap.components(separatedBy: "used = ").last?.components(separatedBy: " ").first, !used.isEmpty {
            let mb = Double(used.replacingOccurrences(of: "M", with: "")) ?? 0
            let heavy = used.hasSuffix("M") && mb > 3072 || used.contains("G")
            out.append(HealthCheck(name: "Swap đang dùng", detail: used, status: heavy ? .warn : .good))
        }

        let sip = Shell.run("/usr/bin/csrutil", ["status"]).lowercased()
        out.append(HealthCheck(name: "SIP (bảo vệ hệ thống)",
            detail: sip.contains("enabled") ? "Bật" : "Tắt", status: sip.contains("enabled") ? .good : .warn))

        let fv = Shell.run("/usr/bin/fdesetup", ["status"]).lowercased()
        out.append(HealthCheck(name: "FileVault (mã hoá đĩa)",
            detail: fv.contains("on") ? "Bật" : "Tắt", status: fv.contains("on") ? .good : .warn))

        let gk = Shell.run("/usr/sbin/spctl", ["--status"]).lowercased()
        out.append(HealthCheck(name: "Gatekeeper",
            detail: gk.contains("enabled") ? "Bật" : "Tắt", status: gk.contains("enabled") ? .good : .warn))

        let smart = Shell.run("/usr/sbin/diskutil", ["info", "/"]).lowercased()
        let verified = smart.contains("verified")
        out.append(HealthCheck(name: "SMART (sức khoẻ ổ)",
            detail: verified ? "Verified" : (smart.contains("not supported") ? "Không hỗ trợ" : "—"),
            status: verified ? .good : (smart.contains("failing") ? .bad : .good)))

        let ver = Shell.run("/usr/bin/sw_vers", ["-productVersion"]).trimmingCharacters(in: .whitespacesAndNewlines)
        out.append(HealthCheck(name: "macOS", detail: ver.isEmpty ? "—" : ver, status: .good))

        let up = Shell.sh("uptime | sed 's/.*up //; s/,[^,]*users.*//'").trimmingCharacters(in: .whitespacesAndNewlines)
        if !up.isEmpty { out.append(HealthCheck(name: "Uptime", detail: up, status: .good)) }

        return out
    }
}
