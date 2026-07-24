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
            self.checks = result.checks
            self.score = result.score
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

    /// mole's `status --json` supplies the authoritative 0–100 score plus
    /// hardware/CPU/RAM/swap rows; the native security checks below cover what
    /// mole doesn't (SIP · FileVault · Gatekeeper · SMART · disk free). When
    /// mole is absent the score falls back to `scoreOf` over the native rows.
    nonisolated static func gather() -> (checks: [HealthCheck], score: Int) {
        var out: [HealthCheck] = []
        var score = 0

        if let s = try? Mole.status() {
            score = s.healthScore
            if let hw = s.hardware {
                if let m = hw.model, !m.isEmpty { out.append(HealthCheck(name: "Máy", detail: m, status: .good)) }
                if let os = hw.osVersion, !os.isEmpty { out.append(HealthCheck(name: "macOS", detail: os, status: .good)) }
                if let cpu = hw.cpuModel, !cpu.isEmpty {
                    let usage = s.cpu?.usage
                    let detail = usage != nil ? "\(cpu) · \(Int(usage!.rounded()))%" : cpu
                    out.append(HealthCheck(name: "CPU", detail: detail, status: (usage ?? 0) > 85 ? .warn : .good))
                }
            }
            if let mem = s.memory {
                let pct = mem.usedPercent ?? 0
                out.append(HealthCheck(name: "RAM",
                    detail: "\(ByteFormat.string(Int64(mem.used ?? 0))) / \(ByteFormat.string(Int64(mem.total ?? 0))) (\(Int(pct))%)",
                    status: pct > 90 ? .warn : .good))
                let swap = Int64(mem.swapUsed ?? 0)
                out.append(HealthCheck(name: "Swap đang dùng", detail: ByteFormat.string(swap),
                    status: swap > 3 * 1_073_741_824 ? .warn : .good))
            }
            if let up = s.uptime, !up.isEmpty { out.append(HealthCheck(name: "Uptime", detail: up, status: .good)) }
        }

        out.append(contentsOf: securityChecks())
        if score == 0 { score = scoreOf(out) }
        return (out, score)
    }

    /// Read-only security/health checks mole doesn't expose. No sudo.
    nonisolated static func securityChecks() -> [HealthCheck] {
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

        return out
    }
}
