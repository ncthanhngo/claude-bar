#!/usr/bin/env bash
# Update the installed app at /Applications with the latest dist/ build.
# Kills any running instance, copies fresh, and relaunches.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/Claude Widget.app"
DEST="/Applications/Claude Widget.app"

# Always rebuild — picks up Info.plist + code changes since last invocation.
echo "▶ Rebuilding .app…"
bash "$ROOT/scripts/build-app.sh"

echo "▶ Killing running instance (if any)…"
killall ClaudeWidget 2>/dev/null || true
sleep 0.5

echo "▶ Removing old install…"
rm -rf "$DEST"

echo "▶ Copying fresh app to /Applications…"
cp -R "$SRC" "$DEST"

# Re-stamp signature. Prefer the stable self-signed identity so Keychain
# ACLs persist across rebuilds; fall back to ad-hoc otherwise.
STABLE_CERT="ClaudeWidget Dev"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "\"$STABLE_CERT\""; then
    codesign --force --deep --sign "$STABLE_CERT" "$DEST" >/dev/null 2>&1 || true
else
    codesign --force --deep --sign - "$DEST" >/dev/null 2>&1 || true
fi

echo "▶ Launching…"
open "$DEST"

sleep 1
if pgrep -f "/Applications/Claude Widget.app" >/dev/null; then
    echo "✓ App is running. Look at the menu bar for the gauge icon."
else
    echo "! App did not start — check Console.app or run from terminal:"
    echo "    \"$DEST/Contents/MacOS/ClaudeWidget\""
fi
