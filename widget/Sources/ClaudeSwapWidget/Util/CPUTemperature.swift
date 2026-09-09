import Foundation
import IOKit

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

// MARK: - Minimal AppleSMC user client

/// Just enough of the AppleSMC IOKit protocol to enumerate keys and read
/// `flt ` values. Uses the 80-byte `SMCKeyData_t` struct as a raw buffer:
///   0  key (UInt32)        28 keyInfo.dataSize (UInt32)   40 result (UInt8)
///   32 keyInfo.dataType    42 data8 = selector (UInt8)    44 data32 (UInt32)
///   48 bytes[32] (payload)
private final class SMC {
    static let shared = SMC()

    private let connection: io_connect_t
    private static let structSize = 80
    private enum Selector { static let readKey: UInt8 = 5, keyFromIndex: UInt8 = 8, keyInfo: UInt8 = 9 }

    private init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        guard kr == KERN_SUCCESS else { return nil }
        connection = conn
    }

    deinit { IOServiceClose(connection) }

    /// Four-character key name (e.g. "Tp01") from its big-endian packed form.
    static func name(of key: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((key >> UInt32($0)) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    private static func pack(_ name: String) -> UInt32 {
        name.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// Every key in the SMC table, via `#KEY` count + key-from-index lookups.
    func allKeys() -> [UInt32] {
        guard let info = keyInfo(Self.pack("#KEY")),
              let out = call(request(key: Self.pack("#KEY"), selector: Selector.readKey, info: info))
        else { return [] }
        let count = Int(out.load(UInt32.self, at: 48).bigEndian)
        return (0..<count).compactMap { index in
            var req = [UInt8](repeating: 0, count: Self.structSize)
            req.store(UInt32(index), at: 44)
            req[42] = Selector.keyFromIndex
            return call(req)?.load(UInt32.self, at: 0)
        }
    }

    /// A key known to hold a 4-byte `flt ` value, with its type info cached so
    /// each later read is a single SMC round-trip.
    struct FloatKey { let key: UInt32; fileprivate let info: KeyInfo }

    /// Resolves the key's type; nil unless it is a 4-byte `flt `.
    func floatKey(_ key: UInt32) -> FloatKey? {
        guard let info = keyInfo(key), info.size == 4, Self.name(of: info.type) == "flt " else { return nil }
        return FloatKey(key: key, info: info)
    }

    /// Live value of a float key, or nil on any protocol error.
    func readFloat(_ fk: FloatKey) -> Float? {
        call(request(key: fk.key, selector: Selector.readKey, info: fk.info))?.load(Float.self, at: 48)
    }

    // MARK: Protocol plumbing

    fileprivate struct KeyInfo { let size: UInt32; let type: UInt32 }

    private func keyInfo(_ key: UInt32) -> KeyInfo? {
        var req = [UInt8](repeating: 0, count: Self.structSize)
        req.store(key, at: 0)
        req[42] = Selector.keyInfo
        guard let out = call(req) else { return nil }
        return KeyInfo(size: out.load(UInt32.self, at: 28), type: out.load(UInt32.self, at: 32))
    }

    private func request(key: UInt32, selector: UInt8, info: KeyInfo) -> [UInt8] {
        var req = [UInt8](repeating: 0, count: Self.structSize)
        req.store(key, at: 0)
        req.store(info.size, at: 28)
        req.store(info.type, at: 32)
        req[42] = selector
        return req
    }

    /// One round-trip; nil when IOKit fails or the SMC reports a non-zero result.
    private func call(_ input: [UInt8]) -> [UInt8]? {
        var input = input
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize
        let kr = IOConnectCallStructMethod(connection, 2, &input, input.count, &output, &outputSize)
        guard kr == KERN_SUCCESS, output[40] == 0 else { return nil }
        return output
    }
}

private extension Array where Element == UInt8 {
    func load<T>(_ type: T.Type, at offset: Int) -> T {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: type) }
    }
    mutating func store<T>(_ value: T, at offset: Int) {
        withUnsafeMutableBytes { $0.storeBytes(of: value, toByteOffset: offset, as: T.self) }
    }
}
