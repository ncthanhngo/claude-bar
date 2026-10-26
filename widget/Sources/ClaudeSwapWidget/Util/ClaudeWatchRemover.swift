import Foundation

/// Removes everything earlier versions installed for the `claude-watch`
/// wrapper: the shell alias, the PATH symlinks, the script and the wrapper
/// registry. Running `claude` sessions re-read the Keychain on their own, so
/// the restart wrapper is no longer needed. Runs on every launch; idempotent
/// and write-free when nothing is left.
enum ClaudeWatchRemover {

    private static let marker = "# Added by Claude Bar"
    private static let aliases = [
        #"alias claude="claude-watch""#,
        #"alias claude="claude-bar-watch""#  // v12.3 rename, reverted
    ]

    static func run() {
        removeShellAliases()
        removeSymlinks()
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("claude-swap-widget")
        try? fm.removeItem(at: support.appendingPathComponent("claude-watch.sh"))
        try? fm.removeItem(at: support.appendingPathComponent("claude-bar-watch.sh"))
        try? fm.removeItem(atPath: ("~/.claude-bar/wrappers" as NSString).expandingTildeInPath)
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

    private static func removeShellAliases() {
        for raw in ["~/.zshrc", "~/.zprofile", "~/.bashrc", "~/.bash_profile"] {
            // Write through a symlinked rc (stow/chezmoi/yadm) instead of
            // replacing the link with a regular file.
            let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
                .resolvingSymlinksInPath().path
            guard let content = try? String(contentsOfFile: path, encoding: .utf8),
                  let stripped = strippedAlias(from: content) else { continue }
            try? stripped.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Only symlinks that point at our script — a user's own `claude-watch`
    /// stays put.
    private static func removeSymlinks() {
        let fm = FileManager.default
        for name in ["claude-watch", "claude-bar-watch"] {
            for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
                let link = "\(dir)/\(name)"
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: link),
                      dest.contains("claude-swap-widget/") else { continue }
                try? fm.removeItem(atPath: link)
            }
        }
    }
}
