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
    ///
    /// Sessions running inside a claude-watch wrapper (tracked in
    /// `~/.claude-bar/wrappers/<pid>.json`) are skipped when
    /// `skipWrapperTracked` is true — `signalWrappers()` already handed the
    /// wrapper a SIGUSR1, and the wrapper performs its own kill+resume so
    /// double-killing here would race the wrapper's escalation timer.
    @discardableResult
    static func killAll(skipCmuxTracked: Bool = false, skipWrapperTracked: Bool = false) -> [KillResult] {
        let cmuxPids: Set<Int> = skipCmuxTracked
            ? Set(CmuxHookSessionReader.readAllActive().compactMap(\.pid))
            : []
        let wrapperChildPids: Set<Int> = skipWrapperTracked
            ? WrapperHookSessionReader.activeChildPids()
            : []
        let sessions = readSessions().filter {
            !cmuxPids.contains($0.pid) && !wrapperChildPids.contains($0.pid)
        }
        return sessions.map { s in
            let sent = kill(Int32(s.pid), SIGINT) == 0
            return KillResult(pid: s.pid, cwd: s.cwd, sent: sent)
        }
    }

    /// Send SIGUSR1 to every active claude-watch wrapper so each wrapper can
    /// snapshot its child's sessionId, stop the child, and re-launch with
    /// `--resume <sid>`. The wrapper preserves conversation across the
    /// reload — unlike the SIGINT path in `killAll()` which leaves a
    /// non-wrapped terminal sitting at a shell prompt.
    ///
    /// Always pair with `killAll(skipWrapperTracked: true)` so the wrapper's
    /// own kill+resume isn't raced by a direct SIGINT here.
    @discardableResult
    static func signalWrappers() -> Int {
        let wrappers = WrapperHookSessionReader.readAllActive()
        var count = 0
        for w in wrappers where kill(Int32(w.wrapperPid), SIGUSR1) == 0 {
            count += 1
        }
        return count
    }

    /// Send SIGKILL to any sessions that are still alive (call after async wait).
    static func forceKillSurvivors(_ results: [KillResult]) {
        for r in results where isAlive(pid: r.pid) {
            kill(Int32(r.pid), SIGKILL)
        }
    }

    /// Reload every running interactive `claude` session after the live
    /// credential or MCP config changed underneath them. Wrapped sessions
    /// (claude-watch) get SIGUSR1 — the wrapper snapshots its child's
    /// sessionId, kills it, and re-launches `claude --resume <sid>` so the
    /// conversation survives and the user never sees a shell prompt. Unwrapped
    /// sessions fall through to SIGINT-then-SIGKILL: they can't auto-restart,
    /// but they still must die so the user's next `claude` launch reads the
    /// fresh credential instead of 401-ing on a rotated-away token. No-op when
    /// nothing is running.
    static func reloadRunningSessions() async {
        signalWrappers()
        let killed = killAll(skipCmuxTracked: true, skipWrapperTracked: true)
        guard !killed.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 800_000_000)
        forceKillSurvivors(killed)
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
