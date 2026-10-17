import Foundation
import IOKit

// MARK: - Minimal AppleSMC user client

/// Just enough of the AppleSMC IOKit protocol to enumerate keys, read values
/// and write them. Uses the 80-byte `SMCKeyData_t` struct as a raw buffer:
///   0  key (UInt32)        28 keyInfo.dataSize (UInt32)   40 result (UInt8)
///   32 keyInfo.dataType    42 data8 = selector (UInt8)    44 data32 (UInt32)
///   48 bytes[32] (payload)
///
/// Reads work for any user; writes are refused by the kernel unless the
/// process runs as root (see the fan helper).
public final class SMC: @unchecked Sendable {
    public static let shared = SMC()

    private let connection: io_connect_t
    private static let structSize = 80
    private enum Selector {
        static let readKey: UInt8 = 5, writeKey: UInt8 = 6, keyFromIndex: UInt8 = 8, keyInfo: UInt8 = 9
    }

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
    public static func name(of key: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((key >> UInt32($0)) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    private static func pack(_ name: String) -> UInt32 {
        name.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// Every key in the SMC table, via `#KEY` count + key-from-index lookups.
    public func allKeys() -> [UInt32] {
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
    public struct FloatKey { public let key: UInt32; fileprivate let info: KeyInfo }

    /// Resolves the key's type; nil unless it is a 4-byte `flt `.
    public func floatKey(_ key: UInt32) -> FloatKey? {
        guard let info = keyInfo(key), info.size == 4, Self.name(of: info.type) == "flt " else { return nil }
        return FloatKey(key: key, info: info)
    }

    /// Live value of a float key, or nil on any protocol error.
    public func readFloat(_ fk: FloatKey) -> Float? {
        call(request(key: fk.key, selector: Selector.readKey, info: fk.info))?.load(Float.self, at: 48)
    }

    // MARK: Access by name

    /// Raw payload of the named key, sized to its type; nil if the key is absent.
    public func read(_ name: String) -> [UInt8]? {
        let key = Self.pack(name)
        guard let info = keyInfo(key),
              let out = call(request(key: key, selector: Selector.readKey, info: info)) else { return nil }
        return Array(out[48..<48 + min(Int(info.size), 32)])
    }

    public func readFloat(_ name: String) -> Float? {
        guard let fk = floatKey(Self.pack(name)) else { return nil }
        return readFloat(fk)
    }

    public func readUInt8(_ name: String) -> UInt8? {
        read(name).flatMap { $0.count == 1 ? $0[0] : nil }
    }

    /// Writes the payload; it must match the key's size exactly. False on any
    /// error, including the kernel refusing a non-root caller.
    @discardableResult
    public func write(_ name: String, _ bytes: [UInt8]) -> Bool {
        let key = Self.pack(name)
        guard let info = keyInfo(key), Int(info.size) == bytes.count else { return false }
        var req = request(key: key, selector: Selector.writeKey, info: info)
        req.replaceSubrange(48..<48 + bytes.count, with: bytes)
        return call(req) != nil
    }

    @discardableResult
    public func writeFloat(_ name: String, _ value: Float) -> Bool {
        write(name, withUnsafeBytes(of: value) { Array($0) })
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
