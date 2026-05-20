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
SESSIONS_DIR="${HOME}/.claude/sessions"
# Seconds to wait for a credential change after claude exits.
# Manual swap: credentials change before SIGINT → detected immediately.
# Auto-swap: widget swaps up to ~sessionPollInterval seconds after exit.
SWAP_WAIT_SEC=8

cred_hash() {
    /usr/bin/shasum -a 256 "$CLAUDE_JSON" 2>/dev/null | cut -d' ' -f1
}

MY_PID=$$
# Per-watcher scratch file holding the most recent sessionId observed for the
# claude child of THIS shell. Lets each terminal restart on its own session
# instead of all racing onto whichever was most recent globally.
SID_FILE=$(/usr/bin/mktemp -t claude-watch-sid.XXXXXX)
trap 'rm -f "$SID_FILE"; [ -n "${WATCHER_PID:-}" ] && kill "$WATCHER_PID" 2>/dev/null || true' EXIT

# Background poller: scans ~/.claude/sessions/*.json for sessions whose process
# is a direct child of this shell, and records the sessionId. Refreshes every
# 0.5s so it catches the session shortly after claude starts.
session_watcher() {
    set +e
    while true; do
        for f in "$SESSIONS_DIR"/*.json; do
            [ -f "$f" ] || continue
            local spid sid ppid
            spid=$(/usr/bin/sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$f" 2>/dev/null | /usr/bin/head -1)
            [ -z "$spid" ] && continue
            ppid=$(ps -o ppid= -p "$spid" 2>/dev/null | /usr/bin/tr -d ' ')
            [ "$ppid" = "$MY_PID" ] || continue
            sid=$(/usr/bin/sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | /usr/bin/head -1)
            [ -n "$sid" ] && printf '%s' "$sid" > "$SID_FILE"
        done
        sleep 0.5
    done
}

session_watcher &
WATCHER_PID=$!

LAST_HASH=$(cred_hash)
FIRST_RUN=true

while true; do
    if $FIRST_RUN; then
        claude "$@" || true
        FIRST_RUN=false
    else
        SID=""
        [ -s "$SID_FILE" ] && SID=$(/bin/cat "$SID_FILE")
        echo ""
        if [ -n "$SID" ]; then
            echo "  ↻  Credentials changed — restarting claude with new account…"
            echo "     (resuming this terminal's session: ${SID})"
            echo ""
            claude --resume "$SID" || claude --continue || claude || true
        else
            echo "  ↻  Credentials changed — restarting claude with new account…"
            echo "     (no session id captured — falling back to --continue)"
            echo ""
            claude --continue || claude || true
        fi
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
