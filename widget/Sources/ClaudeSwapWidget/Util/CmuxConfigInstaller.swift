import Foundation

/// Heals `~/.config/cmux/cmux.json` by removing a stale
/// `automation.claudeBinaryPath = "…/claude-watch"` entry that earlier
/// versions of Claude Bar injected.
///
/// That injection was a mistake. cmux already ships its own `bin/claude`
/// shim, and its `find_real_claude` resolves the real CLI on its own — but
/// only guards against a binary path that points *directly* back at the
/// shim. Pointing it at `claude-watch` slipped past that guard: cmux's shim
/// invoked claude-watch, claude-watch resolved the first `claude` on PATH
/// (cmux prepends its own bin dir, so that's the shim again), and the two
/// wrappers ping-ponged. Each pass through the shim prepended a fresh
/// `--settings <big JSON>` blob until the argument list blew past ARG_MAX —
/// surfacing as "Argument list too long" / a runaway process chain.
///
/// cmux's swap-restart is already covered by CmuxPaneRelauncher (send-key
/// driven), so routing cmux through claude-watch bought nothing. This
/// installer now SWEEPS the bad line out on every launch so existing installs
/// self-heal after one upgrade cycle; cmux then self-resolves the real
/// binary. It never writes a binary path of its own.
enum CmuxConfigInstaller {

    private static let cmuxConfigPath = NSString(string: "~/.config/cmux/cmux.json").expandingTildeInPath

    /// Stale marker written by the old injecting installer — no longer used.
    private static let legacyStateFile: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("claude-swap-widget")
            .appendingPathComponent("cmux-claude-watch-installed.json")
    }()

    /// Called once at app launch. No-ops cleanly when cmux isn't installed.
    static func install() {
        try? FileManager.default.removeItem(at: legacyStateFile)

        guard FileManager.default.fileExists(atPath: cmuxConfigPath),
              let content = try? String(contentsOfFile: cmuxConfigPath, encoding: .utf8),
              let healed = removeClaudeWatchBinaryPath(from: content),
              healed != content else {
            return
        }
        do {
            try healed.write(toFile: cmuxConfigPath, atomically: true, encoding: .utf8)
            DiagnosticsLogger.shared.log(.info, subsystem: "cmux-install",
                "removed stale claudeBinaryPath=claude-watch from cmux.json")
        } catch {
            DiagnosticsLogger.shared.log(.warning, subsystem: "cmux-install",
                "failed to heal cmux.json — \(error.localizedDescription)")
        }
    }

    // MARK: - private

    /// Strips the live (non-comment) `"claudeBinaryPath": "…claude-watch…"`
    /// line. If it was the sole occupant of an `"automation": { … }` block we
    /// created, removes the whole block plus one blank line on each side so no
    /// orphaned scaffolding is left behind. Returns the rewritten content, or
    /// nil if there was nothing to strip.
    private static func removeClaudeWatchBinaryPath(from content: String) -> String? {
        var lines = content.components(separatedBy: "\n")

        guard let pathIdx = lines.firstIndex(where: { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("//") && t.contains("\"claudeBinaryPath\"") && t.contains("claude-watch")
        }) else {
            return nil
        }

        // Prefer removing the enclosing `"automation"` block when we own it
        // outright (nothing but our line and whitespace inside).
        if let openIdx = lines[..<pathIdx].lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("\"automation\"")
        }), let closeIdx = lines[(pathIdx + 1)...].firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t == "}," || t == "}"
        }) {
            let innerNonBlank = (openIdx + 1 ..< closeIdx).filter {
                $0 != pathIdx && !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
            }
            if innerNonBlank.isEmpty {
                var lo = openIdx, hi = closeIdx
                if hi + 1 < lines.count, lines[hi + 1].trimmingCharacters(in: .whitespaces).isEmpty { hi += 1 }
                if lo > 0, lines[lo - 1].trimmingCharacters(in: .whitespaces).isEmpty { lo -= 1 }
                lines.removeSubrange(lo...hi)
                return lines.joined(separator: "\n")
            }
        }

        // Otherwise just drop the single offending line.
        lines.remove(at: pathIdx)
        return lines.joined(separator: "\n")
    }
}
