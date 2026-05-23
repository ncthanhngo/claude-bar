import Foundation
import os

/// Singleton file-backed log sink. Mirrors `os_log` writes at `.error` or
/// higher into `~/Library/Logs/ClaudeBar/claude-bar.log`, plus an explicit
/// API for crash/diagnostic events. Writes are dispatched onto a serial
/// queue so the hot path never blocks on disk I/O.
///
/// Privacy: never log raw tokens, full keychain payloads, or passphrases —
/// only the type + a truncated prefix. The "Send diagnostics" button shows
/// the user the contents before any upload.
final class DiagnosticsLogger: @unchecked Sendable {
    static let shared = DiagnosticsLogger()

    /// Levels written to file. `.debug` and `.info` reach `os_log` only.
    enum Level: String { case info = "INFO", warning = "WARN", error = "ERROR", crash = "CRASH" }

    private let queue = DispatchQueue(label: "dev.ncthanhngo.claude-bar.diagnostics", qos: .utility)
    private let logger = Logger(subsystem: "dev.ncthanhngo.claude-bar", category: "diagnostics")
    private var fileHandle: FileHandle?

    /// `~/Library/Logs/ClaudeBar/`
    let logDirectory: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Logs/ClaudeBar", isDirectory: true)
    }()

    var logFile: URL { logDirectory.appendingPathComponent("claude-bar.log") }

    private init() {}

    /// Idempotent — call early in app launch. Creates the log dir, rotates
    /// the active file if oversize, opens an append handle that survives
    /// the app lifetime. Safe to call multiple times.
    func bootstrap() {
        queue.sync {
            do {
                try FileManager.default.createDirectory(
                    at: logDirectory, withIntermediateDirectories: true)
                LogRotator.rotateIfNeeded(at: logFile.path)
                if !FileManager.default.fileExists(atPath: logFile.path) {
                    FileManager.default.createFile(atPath: logFile.path, contents: nil)
                }
                fileHandle = try FileHandle(forWritingTo: logFile)
                try fileHandle?.seekToEnd()
            } catch {
                logger.error("DiagnosticsLogger bootstrap failed: \(error.localizedDescription)")
            }
        }
        log(.info, subsystem: "app", "Diagnostics bootstrap — pid \(ProcessInfo.processInfo.processIdentifier), version \(appVersion)")
    }

    func log(_ level: Level, subsystem: String, _ message: String) {
        // Mirror to os_log immediately so Console.app sees it even if disk write lags.
        switch level {
        case .info:    logger.info("\(subsystem, privacy: .public) \(message, privacy: .public)")
        case .warning: logger.warning("\(subsystem, privacy: .public) \(message, privacy: .public)")
        case .error, .crash:
            logger.error("\(subsystem, privacy: .public) \(message, privacy: .public)")
        }
        let line = "\(ISO8601DateFormatter.shared.string(from: Date())) · \(level.rawValue) · \(subsystem) · \(message)\n"
        queue.async { [weak self] in
            guard let self else { return }
            guard let data = line.data(using: .utf8), let h = self.fileHandle else { return }
            try? h.write(contentsOf: data)
        }
    }

    /// Forces queued writes to disk. Use before the app terminates or a
    /// signal handler re-raises so the crash line lands in the file.
    func flushSync() {
        queue.sync {
            try? fileHandle?.synchronize()
        }
    }

    /// Reads up to the last N lines of the active log for the "Send
    /// diagnostics" preview. Cheap for tail-of-5MB; reads everything then
    /// suffix-slices — fine for the UI use case.
    func tail(lines: Int = 200) -> String {
        guard let data = try? Data(contentsOf: logFile),
              let text = String(data: data, encoding: .utf8) else { return "" }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        let slice = all.suffix(lines)
        return slice.joined(separator: "\n")
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}

/// Process-wide ISO8601 formatter used by the logger's line format. Stored
/// as a static so we don't allocate one per log line.
extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
