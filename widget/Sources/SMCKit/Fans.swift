import Foundation

/// Live state of one fan, read from the SMC `F<i>..` keys.
public struct FanReading: Equatable, Sendable, Identifiable {
    public let index: Int
    /// Current speed (`F<i>Ac`), RPM.
    public let actual: Double
    /// Hardware limits (`F<i>Mn` / `F<i>Mx`), RPM.
    public let min: Double
    public let max: Double
    /// Speed the SMC is steering towards (`F<i>Tg`), RPM.
    public let target: Double
    /// True when the fan is forced (`F<i>Md` = 1) instead of system-controlled.
    public let isManual: Bool

    public var id: Int { index }

    public init(index: Int, actual: Double, min: Double, max: Double, target: Double, isManual: Bool) {
        self.index = index; self.actual = actual; self.min = min; self.max = max
        self.target = target; self.isManual = isManual
    }
}

/// What the fan helper is asked to do. `arguments` / `parse` are the helper's
/// command line, so app and helper can never disagree on the format.
public enum FanCommand: Equatable, Sendable {
    case auto
    case max
    case rpm(Int)

    public var arguments: [String] {
        switch self {
        case .auto: return ["auto"]
        case .max: return ["max"]
        case .rpm(let v): return ["rpm", String(v)]
        }
    }

    public static func parse(_ args: [String]) -> FanCommand? {
        switch args.first {
        case "auto" where args.count == 1: return .auto
        case "max" where args.count == 1: return .max
        case "rpm" where args.count == 2: return Int(args[1]).flatMap { $0 > 0 ? .rpm($0) : nil }
        default: return nil
        }
    }

    /// Target RPM for a fan with the given limits; nil for `.auto`. A custom
    /// speed is clamped into the fan's range so it can never be stopped or
    /// pushed past its rated maximum.
    public func targetRPM(min: Double, max: Double) -> Double? {
        switch self {
        case .auto: return nil
        case .max: return max
        case .rpm(let v): return Swift.min(Swift.max(Double(v), min), max)
        }
    }
}

/// Apple Silicon fan control via the SMC. Reading works for any user;
/// `apply` needs root and is only called from the fan helper.
public enum Fans {
    public static func read(_ smc: SMC? = SMC.shared) -> [FanReading] {
        guard let smc, let count = smc.readUInt8("FNum") else { return [] }
        return (0..<Int(count)).compactMap { i in
            guard let actual = smc.readFloat("F\(i)Ac"),
                  let lo = smc.readFloat("F\(i)Mn"),
                  let hi = smc.readFloat("F\(i)Mx") else { return nil }
            return FanReading(
                index: i, actual: Double(actual), min: Double(lo), max: Double(hi),
                target: Double(smc.readFloat("F\(i)Tg") ?? actual),
                isManual: (modeKey(i, smc).flatMap { smc.readUInt8($0) } ?? 0) != 0
            )
        }
    }

    /// Applies the command to every fan. Returns false if any write failed.
    public static func apply(_ command: FanCommand, _ smc: SMC? = SMC.shared) -> Bool {
        guard let smc else { return false }
        let fans = read(smc)
        guard !fans.isEmpty else { return false }
        // M1–M3 refuse manual mode while thermalmonitord owns the fans; the
        // `Ftst` diagnostic flag hands them over. Newer chips have no such key.
        let hasUnlock = smc.read("Ftst") != nil
        var ok = true
        for fan in fans {
            guard let mode = modeKey(fan.index, smc) else { return false }
            if let rpm = command.targetRPM(min: fan.min, max: fan.max) {
                if hasUnlock { smc.write("Ftst", [1]) }
                ok = retry { smc.write(mode, [1]) } && ok
                ok = smc.writeFloat("F\(fan.index)Tg", Float(rpm)) && ok
            } else {
                ok = smc.write(mode, [0]) && ok
            }
        }
        if command == .auto && hasUnlock { smc.write("Ftst", [0]) }
        return ok
    }

    /// `F<i>Md` on most chips, `F<i>md` on some newer ones.
    private static func modeKey(_ i: Int, _ smc: SMC) -> String? {
        ["F\(i)Md", "F\(i)md"].first { smc.read($0) != nil }
    }

    /// Right after `Ftst` is set the SMC may still reject the mode change for
    /// a few seconds; retry instead of failing the whole command.
    private static func retry(_ attempt: () -> Bool) -> Bool {
        for _ in 0..<20 {
            if attempt() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }
}
