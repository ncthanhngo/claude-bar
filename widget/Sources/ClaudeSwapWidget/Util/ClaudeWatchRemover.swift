import Foundation

/// Removes everything earlier versions installed for the `claude-watch`
/// wrapper: the shell alias, the PATH symlinks, the script and the wrapper
/// registry. Running `claude` sessions re-read the Keychain on their own, so
/// the restart wrapper is no longer needed. Runs on every launch; idempotent
/// and write-free when nothing is left.
///
/// Users who wrote their own aliases on top of it (`alias cc="claude-watch
/// --model …"`) keep a working `claude-watch`: while any rc file still calls
/// it, the script is turned into a plain passthrough to `claude` instead of
/// being deleted.
enum ClaudeWatchRemover {

    private static let marker = "# Added by Claude Bar"
    private static let aliases = [
        #"alias claude="claude-watch""#,
        #"alias claude="claude-bar-watch""#  // v12.3 rename, reverted
    ]

    static func run() {
        let stillUsed = removeShellAliases()
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("claude-swap-widget")
        let script = support.appendingPathComponent("claude-watch.sh")
        if stillUsed {
            if (try? String(contentsOf: script, encoding: .utf8)) != passthroughScript {
                try? passthroughScript.write(to: script, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            }
        } else {
            removeSymlinks(named: "claude-watch")
            try? fm.removeItem(at: script)
        }
        removeSymlinks(named: "claude-bar-watch")
        try? fm.removeItem(at: support.appendingPathComponent("claude-bar-watch.sh"))
        try? fm.removeItem(atPath: ("~/.claude-bar/wrappers" as NSString).expandingTildeInPath)
    }

    /// True when a non-comment line still invokes `claude-watch`.
    static func referencesClaudeWatch(_ content: String) -> Bool {
        content.components(separatedBy: "\n").contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("#") && t.contains("claude-watch")
        }
    }

    /// Returns `content` without the alias lines (and the marker line right
    /// above each), or nil when there is nothing to remove.
    static func strippedAlias(from content: String) -> String? {
        var lines = content.components(separatedBy: "\n")
        var changed = false
        var i = 0
        while i < lines.count {
            guard aliases.contains(lines[i].trimmingCharacters(in: .whitespaces)) else {
                i += 1
                continue
            }
            changed = true
            lines.remove(at: i)
            if i > 0, lines[i - 1] == marker {
                lines.remove(at: i - 1)
                i -= 1
                // The installer wrote "\n<marker>\n<alias>\n": drop the blank
                // separator it added too.
                if i > 0, lines[i - 1].isEmpty, i < lines.count {
                    lines.remove(at: i - 1)
                    i -= 1
                }
            }
        }
        return changed ? lines.joined(separator: "\n") : nil
    }

    /// Returns whether any rc file still calls `claude-watch` afterwards.
    private static func removeShellAliases() -> Bool {
        var stillUsed = false
        for raw in ["~/.zshrc", "~/.zprofile", "~/.bashrc", "~/.bash_profile"] {
            // Write through a symlinked rc (stow/chezmoi/yadm) instead of
            // replacing the link with a regular file.
            let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
                .resolvingSymlinksInPath().path
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let stripped = strippedAlias(from: content)
            if let stripped {
                try? stripped.write(toFile: path, atomically: true, encoding: .utf8)
            }
            stillUsed = stillUsed || referencesClaudeWatch(stripped ?? content)
        }
        return stillUsed
    }

    /// Only symlinks that point at our script — a user's own `claude-watch`
    /// stays put.
    private static func removeSymlinks(named name: String) {
        let fm = FileManager.default
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let link = "\(dir)/\(name)"
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: link),
                  dest.contains("claude-swap-widget/") else { continue }
            try? fm.removeItem(atPath: link)
        }
    }

    /// Execs the first real `claude` on PATH, skipping anything that resolves
    /// back to this wrapper so it can never recurse.
    private static let passthroughScript = #"""
    #!/usr/bin/env bash
    # claude-watch is retired: Claude Bar no longer restarts claude after a swap.
    # Kept as a passthrough because a shell alias still calls it. Replace
    # `claude-watch` with `claude` there and Claude Bar removes this file.
    IFS=:
    for dir in $PATH; do
        c="$dir/claude"
        [ -x "$c" ] || continue
        case "$(/usr/bin/readlink "$c" 2>/dev/null)" in *claude-watch*) continue ;; esac
        exec "$c" "$@"
    done
    echo "claude-watch: claude not found on PATH" >&2
    exit 127

    """#
}
