import Foundation

/// Detects running Claude Code CLI processes by shelling out to `pgrep`.
///
/// Filtering rule: keep only PIDs whose `argv[0]` basename is exactly `claude`.
/// This excludes Claude.app desktop helpers (`Claude Helper`), the auto-updater
/// (`ShipIt`), and anything that just *mentions* "claude" in its args.
enum ClaudeProcessDetector {

    /// Returns PIDs of currently-running Claude Code CLI processes.
    /// Safe to call from any thread; spawns a subprocess (~10-20 ms).
    static func runningPIDs() -> [Int32] {
        let raw = pgrepOutput()
        guard !raw.isEmpty else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return parsePgrepOutput(raw, excludingPID: ownPID)
    }

    // MARK: - Pure-logic helpers (internal for testability)

    /// Parses lines of `pgrep -lf claude` output into PIDs that are
    /// actual Claude Code CLI invocations. Each line is `PID <argv>`.
    /// Filters out the widget's own PID and any process whose argv[0]
    /// basename isn't exactly `claude`.
    static func parsePgrepOutput(_ raw: String, excludingPID excluded: Int32) -> [Int32] {
        var pids: [Int32] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let pid = Int32(parts[0]),
                  pid != excluded else { continue }

            let argv0 = parts[1].split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if isClaudeCLI(executablePath: argv0) {
                pids.append(pid)
            }
        }
        return pids
    }

    /// `argv[0]` is the executable path. Only accept it if the file's basename
    /// is exactly `claude` (case-sensitive — the CLI binary uses lowercase).
    static func isClaudeCLI(executablePath: String) -> Bool {
        let basename = (executablePath as NSString).lastPathComponent
        return basename == "claude"
    }

    private static func pgrepOutput() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-lf", "claude"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        // pgrep exits non-zero when no match — that's not an error, just empty.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
