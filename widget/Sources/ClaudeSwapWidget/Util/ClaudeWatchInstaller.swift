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
        removeLegacyClaudeBarWatchArtifacts()
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

    /// v12.3 briefly renamed the wrapper to `claude-bar-watch`. The rename was
    /// reverted, but users who upgraded through v12.3 still have leftover
    /// symlinks, the old script in Application Support, and a duplicate alias
    /// in their shell rc files — gnarly enough that typing `claude-bar-watch`
    /// directly still hits the broken v12.3 wrapper. Sweep those on every
    /// launch so the rename leaves no trace after one upgrade cycle.
    private static func removeLegacyClaudeBarWatchArtifacts() {
        let fm = FileManager.default

        let legacySymlinks = [
            "/opt/homebrew/bin/claude-bar-watch",
            "/usr/local/bin/claude-bar-watch"
        ]
        for path in legacySymlinks {
            let binDir = URL(fileURLWithPath: path).deletingLastPathComponent().path
            guard fm.isWritableFile(atPath: binDir),
                  fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil else { continue }
            try? fm.removeItem(atPath: path)
        }

        let legacyScript = scriptDestination
            .deletingLastPathComponent()
            .appendingPathComponent("claude-bar-watch.sh")
        try? fm.removeItem(at: legacyScript)

        let legacyAlias = #"alias claude="claude-bar-watch""#
        let marker = "# Added by Claude Bar"
        let legacyBlock = "\n\(marker)\n\(legacyAlias)\n"

        let profiles = ["~/.zshrc", "~/.zprofile", "~/.bashrc", "~/.bash_profile"]
        for rawPath in profiles {
            let path = (rawPath as NSString).expandingTildeInPath
            guard fm.fileExists(atPath: path),
                  var content = try? String(contentsOfFile: path, encoding: .utf8),
                  content.contains(legacyAlias) else { continue }

            // First sweep removes the full block written by v12.3's installer.
            // Second sweep catches any stray `alias claude="claude-bar-watch"`
            // line in case the marker was edited or the block got reflowed.
            content = content.replacingOccurrences(of: legacyBlock, with: "")
            content = content
                .components(separatedBy: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces) != legacyAlias }
                .joined(separator: "\n")

            try? content.write(toFile: path, atomically: true, encoding: .utf8)
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
# claude-watch — runs `claude` and auto-restarts when:
#   (a) account credentials change (existing flow — swap account)
#   (b) Claude Bar sends SIGUSR1 (MCP config / connector toggled — reload)
#
# Use together with Claude Bar's "Auto-kill CLI" toggle.
#
# Install:
#   chmod +x this-file && ln -sf this-file /usr/local/bin/claude-watch
#
# Usage:
#   claude-watch          # same as `claude`, but restarts after account swap
#   claude-watch [args]   # passes args to claude on first launch only

set -uo pipefail

# ---------------------------------------------------------------------------
# Resolve the REAL claude binary up front, then call it explicitly everywhere
# below instead of a bare `claude`.
#
# Claude Bar installs `alias claude="claude-watch"` in the user's shell rc AND
# points cmux's automation.claudeBinaryPath at this wrapper. A bare `claude`
# call inside this script is therefore only safe in a plain non-interactive
# bash (where the alias is inert). But cmux launches the configured binary
# through an interactive login shell, where `claude` resolves back to
# claude-watch — so the wrapper re-invokes ITSELF instead of the CLI, and each
# round spawns another wrapper + session_watcher pair. Left unchecked this is
# an unbounded process chain. Resolving the actual binary once and invoking it
# directly makes self-recursion structurally impossible.
resolve_real_claude() {
    local dir candidate resolved
    local IFS=:
    for dir in $PATH; do
        candidate="$dir/claude"
        [ -x "$candidate" ] || continue
        resolved="$candidate"
        # Follow one symlink hop so a claude->claude-watch link is caught.
        [ -L "$candidate" ] && resolved="$(/usr/bin/readlink "$candidate" 2>/dev/null || echo "$candidate")"
        case "$resolved" in
            *claude-watch*) continue ;;   # skip our own wrapper — never re-enter
        esac
        printf '%s' "$candidate"
        return 0
    done
    return 1
}

CLAUDE_BIN="$(resolve_real_claude)"
[ -n "$CLAUDE_BIN" ] || CLAUDE_BIN="claude"

# Re-entry guard: if a nested invocation still reaches this script, hand off
# straight to the resolved binary instead of wrapping a second time.
if [ -n "${CLAUDE_WATCH_ACTIVE:-}" ]; then
    exec "$CLAUDE_BIN" "$@"
fi
export CLAUDE_WATCH_ACTIVE=1

CLAUDE_JSON="${HOME}/.claude.json"
SESSIONS_DIR="${HOME}/.claude/sessions"
# Seconds to wait for a credential change after claude exits before treating
# the exit as user-initiated and quitting the watcher.
#
# Used to be 8s — long enough for a slow auto-swap, but felt like the
# terminal had hung when the user just typed /exit. 2s is plenty: the widget
# completes its keychain write in well under a second after SIGINT'ing
# claude. If a future slow-disk scenario needs more, bump cautiously.
SWAP_WAIT_SEC=2

# Registry directory the widget scans to discover wrapper instances. Each
# wrapper writes one JSON file keyed by its own PID; the widget sends
# SIGUSR1 to wrapperPid when MCP config changes so the wrapper does a
# graceful restart with --resume instead of leaving the user at a shell
# prompt.
WRAPPER_REGISTRY_DIR="${HOME}/.claude-bar/wrappers"
mkdir -p "$WRAPPER_REGISTRY_DIR" 2>/dev/null || true

MY_PID=$$
WRAPPER_REGISTRY_FILE="${WRAPPER_REGISTRY_DIR}/${MY_PID}.json"

# Per-watcher scratch file holding the most recent sessionId observed for the
# claude child of THIS shell. Lets each terminal restart on its own session
# instead of all racing onto whichever was most recent globally.
SID_FILE=$(/usr/bin/mktemp -t claude-watch-sid.XXXXXX)

# Tracks the currently-running claude child so the SIGUSR1 handler can
# SIGINT it. Empty between iterations.
CLAUDE_PID=""
# Flips to 1 when SIGUSR1 hit during this iteration; tells the main loop
# to skip the cred-poll and go straight to a --resume restart.
FORCE_RESTART=0
# Tracks whether the next restart was triggered by SIGUSR1 (MCP reload)
# vs the legacy credential-swap path, so the printed banner can match.
FORCE_RESTART_PRINT=0

cred_hash() {
    /usr/bin/shasum -a 256 "$CLAUDE_JSON" 2>/dev/null | cut -d' ' -f1
}

write_wrapper_registry() {
    local child="${1:-}"
    local tmp="${WRAPPER_REGISTRY_FILE}.tmp.$$"
    if [ -n "$child" ]; then
        printf '{"wrapperPid":%d,"childPid":%d}\n' "$MY_PID" "$child" > "$tmp" 2>/dev/null || return 0
    else
        printf '{"wrapperPid":%d,"childPid":null}\n' "$MY_PID" > "$tmp" 2>/dev/null || return 0
    fi
    mv -f "$tmp" "$WRAPPER_REGISTRY_FILE" 2>/dev/null || true
}

read_session_id_for() {
    local pid="${1:-}"
    [ -n "$pid" ] || return 1
    local file="$SESSIONS_DIR/${pid}.json"
    [ -r "$file" ] || return 1
    /usr/bin/sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p' "$file" 2>/dev/null | /usr/bin/head -n1
}

# Claude stores per-cwd conversation history under
# ~/.claude/projects/<sanitized-cwd>/<uuid>.jsonl, where the sanitization
# is "replace every / with -". `claude --continue` only works when at
# least one jsonl exists for the current cwd — otherwise it prints
# "No conversation found to continue" and exits immediately. Without
# this guard the wrapper happily restarts into an unrecoverable state
# whenever credentials change before the user has typed anything.
has_continuable_history() {
    local cwd sanitized dir
    cwd="$(pwd 2>/dev/null)" || return 1
    sanitized="${cwd//\//-}"
    dir="${HOME}/.claude/projects/${sanitized}"
    [ -d "$dir" ] || return 1
    /bin/ls "$dir"/*.jsonl >/dev/null 2>&1
}

# Kill the session_watcher subprocess hard on script exit. SIGTERM was
# sometimes ignored by a bash subshell mid-`sleep`, leaving an orphan
# process attached to the terminal so the shell prompt never returned —
# the symptom users see is the terminal "hanging" after /exit until
# Ctrl+C breaks them out. SIGKILL guarantees the cleanup actually runs.
cleanup_all() {
    rm -f "$SID_FILE" "$WRAPPER_REGISTRY_FILE" 2>/dev/null
    [ -n "${WATCHER_PID:-}" ] && kill -KILL "$WATCHER_PID" 2>/dev/null || true
}
trap cleanup_all EXIT

# SIGUSR1 handler: Claude Bar fires this when MCP config changes so the
# user's running claude session reloads without dropping to a shell prompt.
# Snapshot the current sessionId before signalling — claude removes its
# session JSON shortly after exit, and the background watcher polls at
# 0.5s cadence which can miss the freshest id on a snappy reload.
on_sigusr1() {
    if [ -n "$CLAUDE_PID" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
        local sid
        sid="$(read_session_id_for "$CLAUDE_PID")"
        [ -n "$sid" ] && printf '%s' "$sid" > "$SID_FILE"
        FORCE_RESTART=1
        kill -INT "$CLAUDE_PID" 2>/dev/null || true
        # claude traps SIGINT for in-app cancel. Escalate after a beat so
        # the reload actually happens instead of just cancelling whatever
        # the user was typing.
        (
            sleep 1
            kill -0 "$CLAUDE_PID" 2>/dev/null && kill -TERM "$CLAUDE_PID" 2>/dev/null || true
            sleep 1
            kill -0 "$CLAUDE_PID" 2>/dev/null && kill -KILL "$CLAUDE_PID" 2>/dev/null || true
        ) &
    fi
}
trap on_sigusr1 USR1

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
write_wrapper_registry ""

FIRST_RUN=true

while true; do
    if $FIRST_RUN; then
        "$CLAUDE_BIN" "$@" &
        CLAUDE_PID=$!
        FIRST_RUN=false
    else
        SID=""
        [ -s "$SID_FILE" ] && SID=$(/bin/cat "$SID_FILE")
        echo ""
        if [ -n "$SID" ]; then
            if [ "$FORCE_RESTART_PRINT" = "1" ]; then
                echo "  ↻  Reloading claude (MCP config changed) — resuming session ${SID}…"
            else
                echo "  ↻  Credentials changed — restarting claude with new account…"
                echo "     (resuming this terminal's session: ${SID})"
            fi
            echo ""
            "$CLAUDE_BIN" --resume "$SID" &
            CLAUDE_PID=$!
        else
            if has_continuable_history; then
                if [ "$FORCE_RESTART_PRINT" = "1" ]; then
                    echo "  ↻  Reloading claude (MCP config changed) — continuing latest conversation in this directory…"
                else
                    echo "  ↻  Credentials changed — restarting claude with new account…"
                    echo "     (no session id captured — continuing latest conversation in this directory)"
                fi
                echo ""
                "$CLAUDE_BIN" --continue &
            else
                if [ "$FORCE_RESTART_PRINT" = "1" ]; then
                    echo "  ↻  Reloading claude (MCP config changed) — starting fresh session…"
                else
                    echo "  ↻  Credentials changed — restarting claude with new account…"
                    echo "     (no session id captured and no prior conversation — starting fresh)"
                fi
                echo ""
                "$CLAUDE_BIN" &
            fi
            CLAUDE_PID=$!
        fi
    fi
    FORCE_RESTART_PRINT=0
    write_wrapper_registry "$CLAUDE_PID"

    # `wait` returns early when a trap fires; loop until child is actually dead.
    while kill -0 "$CLAUDE_PID" 2>/dev/null; do
        wait "$CLAUDE_PID" 2>/dev/null
    done

    # SIGUSR1 path: Claude Bar requested an MCP reload. Restart immediately
    # without the cred-poll wait — we already know why claude exited.
    if [ "$FORCE_RESTART" = "1" ]; then
        FORCE_RESTART=0
        FORCE_RESTART_PRINT=1
        continue
    fi

    # Snapshot credentials AT THE INSTANT claude exited. Restart only when a
    # swap happens AFTER this point (within SWAP_WAIT_SEC) — the auto-swap
    # path lands here because the widget completes its write a beat after
    # SIGINT'ing claude.
    #
    # Previously we compared against a script-init hash, which meant any
    # manual swap that happened mid-session would already differ from
    # baseline by the time the user typed `/exit`. The script then
    # interpreted "user wanted to swap and continue chatting; just exited
    # naturally" as "swap pending; restart" — and the user could never
    # escape the terminal. Comparing against the post-exit snapshot
    # restricts the restart trigger to its actual intended window.
    EXIT_HASH=$(cred_hash)
    DEADLINE=$((SECONDS + SWAP_WAIT_SEC))
    NEW_HASH="$EXIT_HASH"
    while [ "$NEW_HASH" = "$EXIT_HASH" ] && [ $SECONDS -lt $DEADLINE ]; do
        sleep 0.5
        NEW_HASH=$(cred_hash)
    done

    if [ "$NEW_HASH" = "$EXIT_HASH" ]; then
        # No credential change detected within the post-exit window —
        # treat this as a user-initiated /exit and quit the watcher.
        break
    fi
    # Credentials changed AFTER claude exited → auto-swap landed → restart.
done
"""#
