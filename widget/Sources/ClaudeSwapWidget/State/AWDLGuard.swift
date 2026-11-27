import Foundation
import Darwin

/// Keeps AWDL (`awdl0`, the Apple Wireless Direct Link used by AirDrop,
/// Handoff, Sidecar and AirPlay-to-Mac) down while "Always turn off AWDL" is
/// on. macOS brings awdl0 back up on its own whenever one of those features
/// wants it, so this watches the kernel's routing socket for interface
/// changes and puts awdl0 down again the moment it comes up. A slow timer
/// backs the socket up in case a message is ever missed.
///
/// Turning the interface down needs root, so it goes through
/// `ClaudeBarNetHelper`, a setuid-root tool installed once behind the admin
/// password prompt (see `PrivilegedHelper`). Only works while the app runs.
@MainActor
final class AWDLGuard: ObservableObject {
    static let shared = AWDLGuard()

    /// Current state of awdl0; nil when this Mac has no AWDL interface.
    @Published private(set) var isUp: Bool?
    /// How many times macOS turned AWDL back on and the guard turned it off,
    /// since the app launched.
    @Published private(set) var reDisableCount = 0
    @Published private(set) var lastReDisable: Date?
    @Published private(set) var isApplying = false
    /// User-facing reason the last change failed; nil when it worked.
    @Published private(set) var error: String?

    private var enabled = false
    private var source: DispatchSourceRead?
    private var timer: Timer?
    private var lastForce = Date.distantPast
    /// The first down after enabling (or launch) is not a "macOS re-enabled
    /// it" event, so it isn't counted.
    private var countNextForce = false

    private nonisolated static let interface = "awdl0"
    /// Never force more than once per this many seconds, so a feature that
    /// keeps raising AWDL can't make the guard spin.
    private nonisolated static let minForceGap: TimeInterval = 1

    private init() {}

    /// Called on launch and whenever the setting changes.
    func apply(enabled newValue: Bool) {
        startMonitoring()
        refresh()
        let wasEnabled = enabled
        enabled = newValue
        error = nil
        if newValue {
            countNextForce = false
            if isUp == true { forceDown() } else { countNextForce = true }
        } else if wasEnabled, isUp == false {
            bringUp()
        }
    }

    // MARK: - State

    private func refresh() {
        isUp = Self.readIsUp()
    }

    private func handle(isUp up: Bool) {
        isUp = up
        if up, enabled { forceDown() }
    }

    private func forceDown() {
        guard !isApplying, Date().timeIntervalSince(lastForce) >= Self.minForceGap else { return }
        lastForce = Date()
        let counted = countNextForce
        run("down") { [weak self] ok in
            guard let self, ok else { return }
            self.countNextForce = true
            if counted {
                self.reDisableCount += 1
                self.lastReDisable = Date()
                DiagnosticsLogger.shared.log(.info, subsystem: "awdl", "awdl0 came back up; turned it off again")
            }
        }
    }

    private func bringUp() {
        // Nothing to undo if the helper was never installed.
        guard PrivilegedHelper.net.isInstalled else { return }
        run("up") { _ in }
    }

    private func run(_ action: String, done: @escaping @MainActor (Bool) -> Void) {
        isApplying = true
        Task {
            let result = await Task.detached { Self.runHelper(action) }.value
            isApplying = false
            error = result
            refresh()
            done(result == nil)
            // The interface may have flipped again while the helper ran.
            if enabled, isUp == true { forceDown() }
        }
    }

    /// Installs the helper if needed, then runs it. Returns nil on success,
    /// else a message for Settings. Blocks — call off the main actor.
    nonisolated static func runHelper(_ action: String) -> String? {
        switch PrivilegedHelper.net.ensureInstalled() {
        case .notBundled: return "Không tìm thấy net helper trong app."
        case .denied: return "Cần quyền admin để tắt AWDL."
        case .ok: break
        }
        switch PrivilegedHelper.net.run(["awdl", action]) {
        case 0: return nil
        case 3: return "Net helper không có quyền root."
        default: return "Không đổi được trạng thái awdl0."
        }
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        guard source == nil else { return }
        let fd = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC)
        if fd >= 0 {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
            src.setEventHandler {
                guard let up = Self.drainRouteSocket(fd) else { return }
                Task { @MainActor in AWDLGuard.shared.handle(isUp: up) }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            source = src
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                let guardian = AWDLGuard.shared
                guard let up = Self.readIsUp() else { guardian.isUp = nil; return }
                guardian.handle(isUp: up)
            }
        }
    }

    /// Reads every pending routing message; returns awdl0's latest up/down
    /// state if any message was about it, else nil.
    private nonisolated static func drainRouteSocket(_ fd: Int32) -> Bool? {
        let index = if_nametoindex(interface)
        guard index != 0 else { return nil }
        var latest: Bool?
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            if let up = parseInterfaceInfo(buf, length: n, index: index) { latest = up }
        }
        return latest
    }

    /// Up/down flag from one routing-socket message if it is an RTM_IFINFO
    /// for the given interface index.
    nonisolated static func parseInterfaceInfo(_ buf: [UInt8], length: Int, index: UInt32) -> Bool? {
        guard length >= MemoryLayout<if_msghdr>.size, buf.count >= length else { return nil }
        let msg = buf.withUnsafeBytes { $0.loadUnaligned(as: if_msghdr.self) }
        guard msg.ifm_type == UInt8(RTM_IFINFO), UInt32(msg.ifm_index) == index else { return nil }
        return msg.ifm_flags & IFF_UP != 0
    }

    /// awdl0's up flag from getifaddrs; nil when the interface doesn't exist.
    nonisolated static func readIsUp() -> Bool? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            if String(cString: ifa.pointee.ifa_name) == interface {
                return Int32(ifa.pointee.ifa_flags) & IFF_UP != 0
            }
            cursor = ifa.pointee.ifa_next
        }
        return nil
    }
}
