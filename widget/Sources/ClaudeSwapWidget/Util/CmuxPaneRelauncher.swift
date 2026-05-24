import Foundation

/// Drives the `cmux` CLI to restart `claude` inside every active cmux pane
/// after claude-bar swaps accounts. For each pane:
///   1. send Ctrl-C to interrupt the current process
///   2. wait briefly for the shell prompt to redraw
///   3. send `claude --resume <sid>\n` so the conversation continues
///
/// Panes that pin `CLAUDE_CONFIG_DIR` to an isolated cmux account dir are
/// skipped because claude-bar's global credential swap does not reach them —
/// touching them would conflate two independent account systems.
enum CmuxPaneRelauncher {

    struct RelaunchOutcome {
        let surfaceId: String
        let sessionId: String
        let skipped: SkipReason?
        let succeeded: Bool
    }

    enum SkipReason: String {
        case isolatedConfigDir = "pane pins CLAUDE_CONFIG_DIR to an isolated cmux account dir"
        case cmuxNotInstalled = "cmux binary not found on PATH"
    }

    /// Runs the relaunch for every active pane. Safe to call concurrently with
    /// the IDE/CLI reload tasks — operates only on cmux surfaces.
    @discardableResult
    static func relaunchAll() async -> [RelaunchOutcome] {
        let cmuxPath = locateCmuxBinary()
        let sessions = CmuxHookSessionReader.readAllActive()
        var outcomes: [RelaunchOutcome] = []

        for session in sessions {
            guard cmuxPath != nil else {
                outcomes.append(.init(
                    surfaceId: session.surfaceId,
                    sessionId: session.sessionId,
                    skipped: .cmuxNotInstalled,
                    succeeded: false
                ))
                continue
            }
            guard session.usesDefaultClaudeConfigDir else {
                outcomes.append(.init(
                    surfaceId: session.surfaceId,
                    sessionId: session.sessionId,
                    skipped: .isolatedConfigDir,
                    succeeded: false
                ))
                continue
            }

            let ok = await relaunch(session: session, cmuxBinary: cmuxPath!)
            outcomes.append(.init(
                surfaceId: session.surfaceId,
                sessionId: session.sessionId,
                skipped: nil,
                succeeded: ok
            ))
        }
        return outcomes
    }

    // MARK: - private

    private static func relaunch(session: CmuxClaudeHookSession, cmuxBinary: String) async -> Bool {
        let sendKey = run(
            executable: cmuxBinary,
            arguments: ["send-key", "--surface", session.surfaceId, "ctrl-c"]
        )
        guard sendKey == 0 else { return false }

        try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s for the shell prompt to redraw

        let resumeText = "claude --resume \(session.sessionId)\n"
        let send = run(
            executable: cmuxBinary,
            arguments: ["send", "--surface", session.surfaceId, resumeText]
        )
        return send == 0
    }

    private static func locateCmuxBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/cmux",
            "/usr/local/bin/cmux",
            "/Applications/cmux.app/Contents/MacOS/cmux",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fallback: shell out to `command -v cmux` to follow user PATH from login shell.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-lc", "command -v cmux"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return output.isEmpty ? nil : output
        } catch {
            return nil
        }
    }

    @discardableResult
    private static func run(executable: String, arguments: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            return -1
        }
    }
}
