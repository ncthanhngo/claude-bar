import Foundation

/// Injects `automation.claudeBinaryPath = "/opt/homebrew/bin/claude-watch"`
/// into `~/.config/cmux/cmux.json` so cmux-spawned `claude` sessions go
/// through the wrapper. Without this, cmux invokes the binary directly,
/// bypassing the shell alias — when Claude Bar's auto-kill sends SIGINT
/// after a swap or auto-recovery, the cmux pane's `claude` exits and
/// never restarts, leaving the user with a stale "session expired" prompt
/// the next morning.
///
/// Design choices:
/// - No-op if `~/.config/cmux/cmux.json` doesn't exist (cmux not installed).
/// - Idempotent — if the path is already set (whether to claude-watch or
///   anything else the user picked), we leave the file alone. The state
///   file marks our one-time write so a manual cmux UI change isn't
///   reverted on the next Claude Bar launch.
/// - State file lives under `~/Library/Application Support/claude-swap-widget/`
///   alongside the rest of the app's install state.
enum CmuxConfigInstaller {

    private static let cmuxConfigPath = NSString(string: "~/.config/cmux/cmux.json").expandingTildeInPath
    private static let claudeWatchPath = "/opt/homebrew/bin/claude-watch"

    private static let stateFile: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("claude-swap-widget")
            .appendingPathComponent("cmux-claude-watch-installed.json")
    }()

    /// Called once at app launch. Safe to invoke even when cmux isn't
    /// installed — the missing file path short-circuits.
    static func install() {
        guard FileManager.default.fileExists(atPath: cmuxConfigPath) else {
            return
        }
        if hasAlreadyInjected() {
            return
        }
        guard let content = try? String(contentsOfFile: cmuxConfigPath, encoding: .utf8) else {
            return
        }
        // If `claudeBinaryPath` appears in an UNCOMMENTED line, the user
        // already manages this setting — don't fight them. Comment lines
        // start with `//` after optional whitespace; we treat any other
        // occurrence as live JSONC.
        if hasLiveClaudeBinaryPath(in: content) {
            DiagnosticsLogger.shared.log(.info, subsystem: "cmux-install",
                "cmux.json already has claudeBinaryPath — leaving alone")
            markInjected()
            return
        }
        guard let updated = inject(into: content) else {
            return
        }
        do {
            try updated.write(toFile: cmuxConfigPath, atomically: true, encoding: .utf8)
            markInjected()
            DiagnosticsLogger.shared.log(.info, subsystem: "cmux-install",
                "injected automation.claudeBinaryPath into cmux.json")
        } catch {
            DiagnosticsLogger.shared.log(.warning, subsystem: "cmux-install",
                "failed to write cmux.json — \(error.localizedDescription)")
        }
    }

    /// Scans for `"claudeBinaryPath"` in any non-comment line.
    private static func hasLiveClaudeBinaryPath(in content: String) -> Bool {
        content.split(separator: "\n", omittingEmptySubsequences: false).contains { rawLine in
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { return false }
            return trimmed.contains("\"claudeBinaryPath\"")
        }
    }

    /// Inserts an `"automation"` block right after `"schemaVersion": 1,`.
    /// Returns nil if the schema anchor isn't found — we won't blindly
    /// prepend into an unfamiliar file shape.
    private static func inject(into content: String) -> String? {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let anchorIdx = lines.firstIndex(where: { $0.contains("\"schemaVersion\"") }) else {
            return nil
        }
        var out = lines
        let block = [
            "",
            "  \"automation\": {",
            "    \"claudeBinaryPath\": \"\(claudeWatchPath)\"",
            "  },"
        ]
        out.insert(contentsOf: block, at: anchorIdx + 1)
        return out.joined(separator: "\n")
    }

    private static func hasAlreadyInjected() -> Bool {
        FileManager.default.fileExists(atPath: stateFile.path)
    }

    private static func markInjected() {
        let dir = stateFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = """
        {"installedAt":"\(ISO8601DateFormatter().string(from: Date()))","claudeBinaryPath":"\(claudeWatchPath)"}
        """
        try? payload.write(to: stateFile, atomically: true, encoding: .utf8)
    }
}
