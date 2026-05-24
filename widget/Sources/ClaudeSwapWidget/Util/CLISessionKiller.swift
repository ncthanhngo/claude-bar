import Foundation

/// Kills running interactive `claude` CLI sessions after a swap so the user
/// doesn't inadvertently continue on the old account.
///
/// Only targets `kind: interactive, entrypoint: cli` sessions (not daemons,
/// background agents, or IDE-managed sessions — those are handled separately).
/// Sends SIGINT (graceful shutdown), not SIGKILL.
enum CLISessionKiller {

    struct KillResult {
        let pid: Int
        let cwd: String
        let sent: Bool
    }

    /// Send SIGINT to all interactive CLI sessions. Returns immediately.
    ///
    /// Sessions running inside a cmux pane (tracked in
    /// `~/.cmuxterm/claude-hook-sessions.json`) are skipped when
    /// `skipCmuxTracked` is true so the cmux pane relauncher can drive the
    /// restart with `--resume <sid>` and keep the conversation. Otherwise a
    /// double SIGINT here would race the resume command.
    @discardableResult
    static func killAll(skipCmuxTracked: Bool = false) -> [KillResult] {
        let cmuxPids: Set<Int> = skipCmuxTracked
            ? Set(CmuxHookSessionReader.readAllActive().compactMap(\.pid))
            : []
        let sessions = readSessions().filter { !cmuxPids.contains($0.pid) }
        return sessions.map { s in
            let sent = kill(Int32(s.pid), SIGINT) == 0
            return KillResult(pid: s.pid, cwd: s.cwd, sent: sent)
        }
    }

    /// Send SIGKILL to any sessions that are still alive (call after async wait).
    static func forceKillSurvivors(_ results: [KillResult]) {
        for r in results where isAlive(pid: r.pid) {
            kill(Int32(r.pid), SIGKILL)
        }
    }

    // MARK: - private

    private struct RawSession: Codable {
        let pid: Int
        let kind: String
        let entrypoint: String
        let status: String?
        let cwd: String
    }

    private static func readSessions() -> [RawSession] {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/sessions")
        guard let entries = try? FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }

        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> RawSession? in
                guard let data = try? Data(contentsOf: url),
                      let s = try? JSONDecoder().decode(RawSession.self, from: data),
                      s.kind == "interactive",
                      s.entrypoint == "cli",
                      isAlive(pid: s.pid) else { return nil }
                return s
            }
    }

    private static func isAlive(pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0 || errno == EPERM
    }
}
