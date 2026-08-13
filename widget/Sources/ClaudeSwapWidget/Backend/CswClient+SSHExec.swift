import Foundation

/// Generic SSH command execution over `csw ssh exec` / `csw ssh classify`.
///
/// Used by the server assistant (Sao lưu tab): the active Claude account
/// proposes a command, we classify it to decide whether the confirm sheet is
/// needed, then run it on a tracked host. The command always travels on stdin
/// so neither user nor LLM bytes ever land in argv or shell history.
extension CswClient {

    /// Risk level returned by the Go classifier — the single source of truth
    /// shared with the MCP gateway. `low` runs without a confirm; everything
    /// else gates behind the confirm sheet.
    enum SSHRisk: String, Decodable {
        case low, medium, destructive

        /// True when the command may run straight away (read-only / info).
        var isAutoRunnable: Bool { self == .low }
    }

    struct SSHExecResult: Decodable {
        let stdout: String
        let stderr: String
        let exitCode: Int
        let durationMs: Int64
        let risk: SSHRisk

        var combinedOutput: String {
            stderr.isEmpty ? stdout : stdout + (stdout.isEmpty ? "" : "\n") + "[stderr] " + stderr
        }
    }

    private struct ClassifyResp: Decodable { let risk: SSHRisk }

    /// Classify a command's risk WITHOUT running it.
    func sshClassify(command: String) async throws -> SSHRisk {
        try await runWithStdin(["ssh", "classify"], stdin: command, decode: ClassifyResp.self).risk
    }

    /// Run a command on a tracked host. `timeoutSeconds` is clamped to 1…600
    /// server-side. The command is piped on stdin.
    func sshExec(host: String, command: String, timeoutSeconds: Int = 120) async throws -> SSHExecResult {
        try await runWithStdin(
            ["ssh", "exec", "--host", host, "--timeout", String(timeoutSeconds)],
            stdin: command,
            decode: SSHExecResult.self
        )
    }
}
