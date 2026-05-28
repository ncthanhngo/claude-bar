import Foundation

/// One claude-watch wrapper instance tracked via
/// `~/.claude-bar/wrappers/<wrapper_pid>.json`. The wrapper writes one file
/// per running invocation; on EXIT it removes its own file. Files belonging
/// to wrappers whose PIDs no longer exist are filtered out at read time so
/// crash-orphaned entries don't keep showing up.
///
/// Paired with `CLISessionKiller.signalWrappers()` which sends SIGUSR1 to
/// each wrapper PID when MCP config changes; the wrapper then re-launches
/// `claude --resume <sid>` so the user keeps their conversation.
struct WrapperHookSession {
    let wrapperPid: Int
    /// PID of the real `claude` child the wrapper spawned. May be nil during
    /// the brief window between wrapper start and first child spawn.
    let childPid: Int?
}

enum WrapperHookSessionReader {
    static let defaultDirectory = "~/.claude-bar/wrappers"

    /// Returns every wrapper currently registered whose PID is still alive.
    static func readAllActive(directory: String = defaultDirectory) -> [WrapperHookSession] {
        let expanded = (directory as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard let entries = try? FileManager.default
            .contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        else { return [] }

        return entries.compactMap { fileURL -> WrapperHookSession? in
            guard fileURL.pathExtension == "json",
                  let data = try? Data(contentsOf: fileURL),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let wrapperPid = raw["wrapperPid"] as? Int
            else { return nil }

            guard isAlive(pid: wrapperPid) else {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }

            let childPid = raw["childPid"] as? Int
            return WrapperHookSession(wrapperPid: wrapperPid, childPid: childPid)
        }
    }

    /// Set of child claude PIDs currently owned by an active wrapper. Used
    /// by CLISessionKiller to skip these when sending SIGINT — the wrapper
    /// drives its own restart so a direct kill would race the resume.
    static func activeChildPids(directory: String = defaultDirectory) -> Set<Int> {
        Set(readAllActive(directory: directory).compactMap(\.childPid))
    }

    private static func isAlive(pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0 || errno == EPERM
    }
}
