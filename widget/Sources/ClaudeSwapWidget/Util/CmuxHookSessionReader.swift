import Foundation

/// One Claude session captured by cmux's hook integration. Sourced from
/// `~/.cmuxterm/claude-hook-sessions.json` which cmux populates whenever a
/// `claude` process spawns inside a cmux pane after `cmux hooks setup`.
struct CmuxClaudeHookSession {
    let sessionId: String
    let workspaceId: String
    let surfaceId: String
    let cwd: String?
    let pid: Int?
    /// Snapshot of the env claude was launched with. We read `CLAUDE_CONFIG_DIR`
    /// to know whether this pane is using an isolated per-account config dir
    /// (in which case claude-bar's global swap does NOT reach it).
    let environment: [String: String]

    /// Pane is using cmux's default behavior — claude reads `~/.claude/`, which
    /// is the same file claude-bar swaps. A `--resume <sid>` after swap will
    /// pick up new credentials and keep the conversation.
    var usesDefaultClaudeConfigDir: Bool {
        guard let dir = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dir.isEmpty else {
            return true
        }
        let standardized = (dir as NSString).standardizingPath
        let defaultPath = ((NSHomeDirectory() as NSString).appendingPathComponent(".claude") as NSString).standardizingPath
        return standardized == defaultPath
    }
}

enum CmuxHookSessionReader {
    static let defaultStatePath = "~/.cmuxterm/claude-hook-sessions.json"

    /// Read every active claude session cmux currently tracks. Sessions that
    /// no longer have a live PID are filtered out.
    static func readAllActive(path: String = defaultStatePath) -> [CmuxClaudeHookSession] {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        guard let sessions = root["sessions"] as? [String: [String: Any]] else { return [] }

        return sessions.compactMap { (_, raw) -> CmuxClaudeHookSession? in
            guard let sessionId = raw["sessionId"] as? String, !sessionId.isEmpty,
                  let workspaceId = raw["workspaceId"] as? String, !workspaceId.isEmpty,
                  let surfaceId = raw["surfaceId"] as? String, !surfaceId.isEmpty else {
                return nil
            }
            let pid = raw["pid"] as? Int
            if let pid, !isAlive(pid: pid) { return nil }

            let cwd = (raw["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let launchCommand = raw["launchCommand"] as? [String: Any]
            let environment = (launchCommand?["environment"] as? [String: String]) ?? [:]

            return CmuxClaudeHookSession(
                sessionId: sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: cwd,
                pid: pid,
                environment: environment
            )
        }
    }

    private static func isAlive(pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0 || errno == EPERM
    }
}
