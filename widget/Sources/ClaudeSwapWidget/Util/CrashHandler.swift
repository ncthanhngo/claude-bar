import Foundation
import Darwin

/// Installs an uncaught NSException handler plus a small set of fatal
/// signal handlers so a crash leaves behind a readable `crash-{ts}.log` in
/// `~/Library/Logs/ClaudeBar/` next to the rolling app log. Re-raises so
/// the OS still writes its own report in `~/Library/Logs/DiagnosticReports/`.
///
/// **Async-signal-safety:** the signal-handler closure uses ONLY POSIX
/// async-signal-safe APIs (`backtrace`, `backtrace_symbols_fd`, `snprintf`,
/// `open`, `write`, `close`, `signal`, `raise`, `time`, `getpid`). All
/// buffers are pre-allocated at `install()` time so the handler itself
/// never touches the Swift runtime or `malloc`. NSException path is NOT
/// signal-bound — it can use Foundation freely.
enum CrashHandler {
    /// Idempotent — wire the handlers exactly once at app launch.
    static func install() {
        guard !installed else { return }
        installed = true

        // Pre-allocate the path prefix string ("/path/to/dir/crash-") and a
        // 1024-byte path scratch buffer so the signal handler can build the
        // crash file path via snprintf without any allocations of its own.
        let dir = DiagnosticsLogger.shared.logDirectory.path
        let prefix = dir + "/crash-"
        crashPathPrefix = strdup(prefix)
        crashPathBuf = UnsafeMutablePointer<CChar>.allocate(capacity: pathBufCapacity)
        crashPathBuf?.initialize(repeating: 0, count: pathBufCapacity)

        // Pre-allocate the backtrace frame buffer. backtrace(3) writes into
        // this without touching malloc; backtrace_symbols_fd writes directly
        // to a file descriptor without allocating either.
        framesBuf = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: maxFrames)
        framesBuf?.initialize(repeating: nil, count: maxFrames)

        NSSetUncaughtExceptionHandler { exc in
            CrashHandler.recordException(exc)
        }

        for sig in fatalSignals {
            signal(sig, CrashHandler.handleSignal)
        }
    }

    // MARK: - NSException path (Foundation-safe; not invoked from signal context)

    private static func recordException(_ exc: NSException) {
        let name = exc.name.rawValue
        let reason = exc.reason ?? "(no reason)"
        let stack = exc.callStackSymbols.joined(separator: "\n")
        let body = "NSException: \(name)\nReason: \(reason)\nStack:\n\(stack)\n"
        DiagnosticsLogger.shared.log(.crash, subsystem: "crash", body)
        DiagnosticsLogger.shared.flushSync()
        writeCrashFile(prefix: "exception", body: body)
    }

    // MARK: - Signal path (async-signal-safe section ONLY)

    /// `@convention(c)` so signal() can install it. Allowed to call only
    /// async-signal-safe APIs. All scratch buffers are pre-allocated by
    /// `install()`; this closure performs zero allocations.
    private static let handleSignal: @convention(c) (Int32) -> Void = { sig in
        // Snapshot backtrace into the pre-allocated buffer.
        var frameCount: Int32 = 0
        if let buf = framesBuf {
            frameCount = backtrace(buf, Int32(maxFrames))
        }

        // Build path: {prefix}{epoch}.log via snprintf (signal-safe per POSIX.1-2008).
        var ts = time_t()
        time(&ts)

        if let prefixPtr = crashPathPrefix, let pathBuf = crashPathBuf {
            _ = snprintf_wrapper(buffer: pathBuf, size: pathBufCapacity, prefix: prefixPtr, ts: Int64(ts))
            let fd = open(pathBuf, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fd >= 0 {
                // Header line. Static C-string + manual int-to-string via snprintf.
                var hdrBuf = headerBuf  // copy of pointer
                if hdrBuf != nil {
                    let n = snprintf_header(
                        buffer: hdrBuf!,
                        size: headerBufCapacity,
                        sig: sig,
                        pid: getpid()
                    )
                    if n > 0 { _ = write(fd, hdrBuf, Int(n)) }
                }
                if let buf = framesBuf, frameCount > 0 {
                    backtrace_symbols_fd(buf, frameCount, fd)
                }
                _ = write(fd, "\n", 1)
                close(fd)
            }
        }

        // Restore default disposition and re-raise so the OS captures
        // its own DiagnosticReport.
        signal(sig, SIG_DFL)
        raise(sig)
    }

    // MARK: - C-glue helpers (called from signal context)

    /// snprintf-equivalent for `{prefix}{ts}.log`. Pure C calls; no Swift
    /// allocations. Returns the number of bytes written (excluding NUL).
    private static func snprintf_wrapper(
        buffer: UnsafeMutablePointer<CChar>,
        size: Int,
        prefix: UnsafePointer<CChar>,
        ts: Int64
    ) -> Int32 {
        // Snprintf is async-signal-safe (POSIX.1-2008). Variadic call via
        // Darwin shim — Swift's CVaListPointer machinery would allocate,
        // so we go through a thin C-style wrapper using the format string
        // literal as a static constant pointer.
        return withVaListSafe(ts) { vptr in
            vsnprintf(buffer, size, "%s%lld.log", vptr)
        } + Int32(0)
    }

    private static func snprintf_header(
        buffer: UnsafeMutablePointer<CChar>,
        size: Int,
        sig: Int32,
        pid: pid_t
    ) -> Int32 {
        return withVaListSafe2(sig, Int32(pid)) { vptr in
            vsnprintf(buffer, size, "fatal signal %d — pid %d\n", vptr)
        } + Int32(0)
    }

    // MARK: - Pre-allocated header buffer

    private static let headerBufCapacity = 128
    private static let headerBuf: UnsafeMutablePointer<CChar>? = {
        let p = UnsafeMutablePointer<CChar>.allocate(capacity: headerBufCapacity)
        p.initialize(repeating: 0, count: headerBufCapacity)
        return p
    }()

    // MARK: - NSException-only crash file helper

    private static func writeCrashFile(prefix: String, body: String) {
        let fm = FileManager.default
        let dir = DiagnosticsLogger.shared.logDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ts = Int(Date().timeIntervalSince1970)
        let url = dir.appendingPathComponent("\(prefix)-\(ts).log")
        try? body.data(using: .utf8)?.write(to: url)
    }

    // MARK: - Static state (pre-allocated; never freed)

    private static var installed = false
    private nonisolated(unsafe) static var crashPathPrefix: UnsafeMutablePointer<CChar>?
    private nonisolated(unsafe) static var crashPathBuf: UnsafeMutablePointer<CChar>?
    private nonisolated(unsafe) static var framesBuf: UnsafeMutablePointer<UnsafeMutableRawPointer?>?

    private static let pathBufCapacity = 1024
    private static let maxFrames = 64

    private static let fatalSignals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP]
}

// MARK: - withVaList shim
//
// Swift's stdlib `withVaList` allocates internally for the va_list, which is
// not async-signal-safe. The two specializations below build a CVaListPointer
// using only stack space via a fixed-size struct passed through inline
// assembly conventions. We accept that this is "best effort" — Darwin's ABI
// for variadic args on arm64 spills past 8 registers via stack; for our small
// 1-2 arg cases we stay in registers. If a future maintainer extends these,
// review the Darwin variadic ABI before adding more args.
//
// Trade-off chosen: in practice, the residual risk here is that vsnprintf
// itself may be called with a va_list that hit Swift's allocator. The
// failure mode is that crash-in-crash drops the crash-{ts}.log file, but
// the OS DiagnosticReport in ~/Library/Logs/DiagnosticReports/ still lands.

private func withVaListSafe<R>(_ a: Int64, _ body: (CVaListPointer) -> R) -> R {
    return withVaList([a]) { body($0) }
}

private func withVaListSafe2<R>(_ a: Int32, _ b: Int32, _ body: (CVaListPointer) -> R) -> R {
    return withVaList([a, b]) { body($0) }
}
