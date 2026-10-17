import Foundation
import SMCKit

/// Reads the Mac's CPU core temperature on Apple Silicon from the SMC (System
/// Management Controller) — the same source the Stats / iStat Menus apps use.
/// No sudo and no entitlement required (the app is not sandboxed); `powermetrics`
/// needs root and so can't back a background menu-bar app.
///
/// Why SMC and not the IOKit HID thermal sensors: on M4-class chips the HID
/// tree only exposes `PMU tdie*` / `PMU tdev*` sensors, which are the power
/// management unit's die temperatures — they sit ~20°C below the CPU cores and
/// barely move under load. The per-core CPU sensors live in the SMC under the
/// `Tp` (performance cores) and `Te` (efficiency cores) key prefixes on
/// M1/M2/M4/M5 and `Tf` on M3. We enumerate the SMC key table once, keep every
/// float-typed key with those prefixes, and report the mean of their live
/// values (matching Stats' default "CPU average").
///
/// Power-gated cores are the catch: a P-core that is asleep reports garbage
/// (0, -4, 1.5, 2.3°C observed on M4 Pro at idle) rather than a temperature,
/// so only samples in a physically plausible band are averaged. At idle that
/// leaves the always-on E-cores; under load every core joins the mean.
enum CPUTemperature {

    /// Plausible band for a live CPU core temperature in °C. Silicon never
    /// runs below room temperature, so anything under 10°C is a sleeping
    /// core's placeholder, not a reading; 120°C+ is past thermal shutdown.
    static let plausibleRange: ClosedRange<Double> = 10...119

    /// Key prefixes tried in order; the first prefix set that yields at least
    /// one usable key wins. `Tf` is M3-only and also carries GPU sensors, so it
    /// is a fallback rather than part of the primary set.
    private static let prefixSets: [[String]] = [["Tp", "Te"], ["Tf"]]

    // MARK: - Public API

    /// Current mean CPU core temperature in °C, or `nil` if no live reading is
    /// available (no SMC, no matching keys, or all samples implausible).
    /// Safe to call off the main thread.
    static func readCelsius() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let smc = SMC.shared else { return nil }
        if cpuKeys == nil { cpuKeys = discoverCPUKeys(smc) }
        guard let keys = cpuKeys, !keys.isEmpty else { return nil }
        return average(keys.compactMap { smc.readFloat($0).map(Double.init) })
    }

    /// Mean of the plausible samples, or `nil` if none survive the filter.
    static func average(_ samples: [Double]) -> Double? {
        let values = samples.filter { plausibleRange.contains($0) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    // MARK: - Key discovery (once per process)

    private static let lock = NSLock()
    private static var cpuKeys: [SMC.FloatKey]?

    /// Walks the whole SMC key table (~1.7k keys on M4 Pro) once and keeps the
    /// float-typed temperature keys matching the first usable prefix set.
    private static func discoverCPUKeys(_ smc: SMC) -> [SMC.FloatKey] {
        let floatKeys = smc.allKeys().compactMap { smc.floatKey($0) }
        for prefixes in prefixSets {
            let matched = floatKeys.filter { fk in
                let name = SMC.name(of: fk.key)
                return prefixes.contains { name.hasPrefix($0) }
            }
            if !matched.isEmpty { return matched }
        }
        return []
    }
}
