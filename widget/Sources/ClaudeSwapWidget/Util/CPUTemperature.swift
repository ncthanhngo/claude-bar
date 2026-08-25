import Foundation

/// Reads the Mac's CPU die temperature on Apple Silicon via the private IOKit
/// HID thermal-sensor API — the same mechanism the Stats / iStat Menus apps
/// use. No sudo and no entitlement required (the app is not sandboxed), unlike
/// `powermetrics` which needs root and so can't back a background menu-bar app.
///
/// The needed `IOHIDEventSystemClient*` symbols are exported from
/// IOKit.framework but absent from the public headers, so we resolve them at
/// runtime with `dlsym` and call through `@convention(c)` typealiases. Every
/// lookup is optional: on any missing symbol or empty reading the reader
/// returns `nil` and the UI simply shows nothing.
///
/// Sensor naming is chip-specific. On M-series the CPU/SoC die is exposed as a
/// cluster of `PMU tdie<N>` sensors; we average those. `PMU tcal` is a fixed
/// calibration constant (not a live reading) and `NAND …` is storage, so both
/// are excluded. If no `tdie` sensor is present we fall back to `PMU tdev<N>`
/// (device temperatures) so older/other chips still yield a number.
enum CPUTemperature {

    // MARK: - Private IOKit HID signatures (resolved via dlsym)

    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int32, Int32, Int32) -> Unmanaged<AnyObject>?
    private typealias GetFloat = @convention(c) (AnyObject, Int64) -> Double

    // Apple HID usage page/usage that surfaces the SoC temperature sensors.
    private static let kHIDPageAppleVendor = 0xff00
    private static let kHIDUsageTemperatureSensor = 0x0005
    // kIOHIDEventTypeTemperature = 15; a field id is `type << 16` (event base).
    private static let kEventTypeTemperature: Int32 = 15
    private static let temperatureField: Int64 = Int64(kEventTypeTemperature) << 16

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let ptr = dlsym(dlopen(nil, RTLD_NOW), name) else { return nil }
        return unsafeBitCast(ptr, to: type)
    }

    // MARK: - Public API

    /// Current CPU die temperature in °C, or `nil` if no live reading is
    /// available (missing symbols, no matching sensors, or all readings zero).
    /// Safe to call off the main thread; it holds no shared state.
    static func readCelsius() -> Double? {
        guard
            let create = symbol("IOHIDEventSystemClientCreate", as: ClientCreate.self),
            let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
            let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
            let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
            let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
            let getFloat = symbol("IOHIDEventGetFloatValue", as: GetFloat.self),
            let clientRef = create(kCFAllocatorDefault)
        else { return nil }

        let client = clientRef.takeRetainedValue()
        let matching: [String: Int] = [
            "PrimaryUsagePage": kHIDPageAppleVendor,
            "PrimaryUsage": kHIDUsageTemperatureSensor,
        ]
        setMatching(client, matching as CFDictionary)

        guard let servicesRef = copyServices(client) else { return nil }
        let services = servicesRef.takeRetainedValue() as NSArray

        // Read every matching sensor once, keyed by its product name.
        var readings: [(name: String, value: Double)] = []
        for element in services {
            let service = element as AnyObject
            guard let nameRef = copyProperty(service, "Product" as CFString),
                  let name = nameRef.takeRetainedValue() as? String,
                  let eventRef = copyEvent(service, kEventTypeTemperature, 0, 0)
            else { continue }
            let value = getFloat(eventRef.takeRetainedValue(), temperatureField)
            guard value > 0 else { continue }
            readings.append((name, value))
        }

        return average(readings, matching: "PMU tdie")
            ?? average(readings, matching: "PMU tdev")
    }

    /// Mean of readings whose name has the given prefix, or `nil` if none match.
    private static func average(_ readings: [(name: String, value: Double)],
                                matching prefix: String) -> Double? {
        let values = readings.filter { $0.name.hasPrefix(prefix) }.map(\.value)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
