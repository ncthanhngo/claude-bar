import Foundation

/// Makes the `claude` CLI reachable by the `csw` child processes the app
/// spawns for chat / briefing.
///
/// A GUI app launched from Finder inherits a minimal PATH
/// (`/usr/bin:/bin:/usr/sbin:/sbin`) that excludes where Claude Code installs
/// itself — `~/.claude/local`, `~/.local/bin`, a Homebrew prefix, or an
/// npm/nvm/bun bin dir. So `csw chat` (which does `exec.LookPath("claude")`)
/// fails with "claude binary not on PATH". We resolve the real path once at
/// launch and export it as `CLAUDE_BIN`, which `csw`'s NewChatClient reads
/// before falling back to PATH. Every csw child inherits the exported var.
enum ClaudeBinaryEnv {

    /// Resolve `claude` and export `CLAUDE_BIN` for child processes. Idempotent;
    /// a no-op when `CLAUDE_BIN` is already set to an executable.
    static func ensure() {
        if let existing = ProcessInfo.processInfo.environment["CLAUDE_BIN"],
           isUsable(existing) {
            return
        }
        guard let path = resolve() else { return }
        setenv("CLAUDE_BIN", path, 1)
    }

    /// First usable `claude` from common install locations, then a login-shell
    /// `command -v` fallback (covers npm/nvm/asdf installs under the user's own
    /// PATH). Never returns the claude-watch wrapper — that would self-recurse.
    static func resolve() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.deno/bin/claude",
            "\(home)/.volta/bin/claude",
            "/usr/bin/claude",
        ]
        for c in candidates where isUsable(c) { return c }
        return loginShellLookup()
    }

    /// Ask the user's login shell to resolve `claude` so nvm/npm/asdf shims on
    /// the real PATH are found. Bounded so a misconfigured shell can't hang
    /// launch.
    private static func loginShellLookup() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: shell)
        task.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        // Don't block launch indefinitely on a slow shell rc.
        let deadline = Date().addingTimeInterval(4)
        while task.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if task.isRunning {
            task.terminate()
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return isUsable(path) ? path : nil
    }

    /// Executable, and not the claude-watch wrapper (following one symlink hop).
    private static func isUsable(_ path: String) -> Bool {
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return false }
        let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? path
        return !resolved.contains("claude-watch")
    }
}
