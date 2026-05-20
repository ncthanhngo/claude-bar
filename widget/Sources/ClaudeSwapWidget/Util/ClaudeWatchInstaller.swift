import Foundation

/// Writes the `claude-watch` shell wrapper to
/// ~/Library/Application Support/claude-swap-widget/claude-watch.sh
/// on every launch so the script stays up-to-date with the app.
enum ClaudeWatchInstaller {

    static let scriptDestination: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("claude-swap-widget")
            .appendingPathComponent("claude-watch.sh")
    }()

    static func install() {
        let dir = scriptDestination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? claudeWatchScript.write(to: scriptDestination, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptDestination.path
        )
        installSymlink()
        installShellAlias()
    }

    // MARK: - Auto-setup helpers

    private static let symlinkCandidates = [
        "/opt/homebrew/bin/claude-watch",
        "/usr/local/bin/claude-watch"
    ]

    /// Creates a symlink in the first writable bin dir found on PATH.
    private static func installSymlink() {
        let fm = FileManager.default
        let src = scriptDestination.path
        for linkPath in symlinkCandidates {
            let binDir = URL(fileURLWithPath: linkPath).deletingLastPathComponent().path
            guard fm.isWritableFile(atPath: binDir) else { continue }
            try? fm.removeItem(atPath: linkPath)
            try? fm.createSymbolicLink(atPath: linkPath, withDestinationPath: src)
            break
        }
    }

    /// Appends `alias claude="claude-watch"` to ~/.zshrc / ~/.bashrc if not already present.
    private static func installShellAlias() {
        let alias = #"alias claude="claude-watch""#
        let marker = "# Added by Claude Bar"
        let block = "\n\(marker)\n\(alias)\n"

        let profiles = [
            ("~/.zshrc",         true),   // interactive shells (most terminals)
            ("~/.zprofile",      false),  // login shells (JetBrains built-in terminal on macOS)
            ("~/.bashrc",        false),
            ("~/.bash_profile",  false)
        ]

        for (rawPath, createIfMissing) in profiles {
            let path = (rawPath as NSString).expandingTildeInPath
            let fm = FileManager.default

            if fm.fileExists(atPath: path) {
                guard let existing = try? String(contentsOfFile: path, encoding: .utf8),
                      !existing.contains(alias) else { continue }
                try? (existing + block).write(toFile: path, atomically: true, encoding: .utf8)
            } else if createIfMissing {
                try? block.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}

// MARK: - script source

private let claudeWatchScript = #"""
#!/usr/bin/env bash
# claude-watch — runs `claude` and auto-restarts when account credentials
# change. Use together with Claude Bar's "Auto-kill CLI" toggle.
#
# Install:
#   chmod +x this-file && ln -sf this-file /usr/local/bin/claude-watch
#
# Usage:
#   claude-watch          # same as `claude`, but restarts after account swap
#   claude-watch [args]   # passes args to claude on first launch only

set -euo pipefail

CLAUDE_JSON="${HOME}/.claude.json"
# Seconds to wait for a credential change after claude exits.
# Manual swap: credentials change before SIGINT → detected immediately.
# Auto-swap: widget swaps up to ~sessionPollInterval seconds after exit.
SWAP_WAIT_SEC=8

cred_hash() {
    /usr/bin/shasum -a 256 "$CLAUDE_JSON" 2>/dev/null | cut -d' ' -f1
}

LAST_HASH=$(cred_hash)
FIRST_RUN=true

while true; do
    if $FIRST_RUN; then
        claude "$@" || true
        FIRST_RUN=false
    else
        echo ""
        echo "  ↻  Credentials changed — restarting claude with new account…"
        echo "     (resuming previous conversation context with --continue)"
        echo ""
        claude --continue || claude || true
    fi

    # Poll briefly so auto-swap (which completes after the session ends)
    # is detected in time. Normal /exit: hash stays the same → exits quickly.
    DEADLINE=$((SECONDS + SWAP_WAIT_SEC))
    NEW_HASH=$(cred_hash)
    while [ "$NEW_HASH" = "$LAST_HASH" ] && [ $SECONDS -lt $DEADLINE ]; do
        sleep 0.5
        NEW_HASH=$(cred_hash)
    done

    if [ "$NEW_HASH" = "$LAST_HASH" ]; then
        # No credential change detected — normal exit.
        break
    fi
    # Credentials changed → restart with new account.
    LAST_HASH="$NEW_HASH"
done
"""#
