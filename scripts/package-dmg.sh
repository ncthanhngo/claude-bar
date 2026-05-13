#!/usr/bin/env bash
# Package ClaudeWidget.app into a distributable .dmg installer.
# Usage: bash scripts/package-dmg.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-0.1.0}"
APP_DISPLAY="Claude Widget"
APP_SOURCE="$ROOT/dist/$APP_DISPLAY.app"
DMG_NAME="ClaudeWidget-$VERSION"
DMG_PATH="$ROOT/$DMG_NAME.dmg"
STAGING="$ROOT/dist/.dmg-staging"

# 1. Ensure .app exists (rebuild if missing).
if [[ ! -d "$APP_SOURCE" ]]; then
    echo "▶ .app missing — building first…"
    bash "$ROOT/scripts/build-app.sh"
fi

# 2. Prepare staging directory.
echo "▶ Preparing staging dir…"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_SOURCE" "$STAGING/$APP_DISPLAY.app"
ln -s /Applications "$STAGING/Applications"

# 3. Remove any old DMG.
rm -f "$DMG_PATH"

# 4. Build the DMG (compressed, read-only).
echo "▶ Creating DMG: $DMG_PATH…"
hdiutil create \
    -volname "$APP_DISPLAY" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH" >/dev/null

# 5. Clean staging.
rm -rf "$STAGING"

# 6. Optional ad-hoc sign on the DMG itself (Gatekeeper-friendly-ish).
codesign --force --sign - "$DMG_PATH" >/dev/null 2>&1 || true

SIZE=$(du -h "$DMG_PATH" | awk '{print $1}')
echo
echo "✓ DMG ready: $DMG_PATH ($SIZE)"
echo
echo "Install:"
echo "  open \"$DMG_PATH\"        # double-click in Finder works too"
echo "  → drag '$APP_DISPLAY' onto the 'Applications' alias"
echo
echo "First launch (unsigned):"
echo "  System Settings → Privacy & Security → Open Anyway"
