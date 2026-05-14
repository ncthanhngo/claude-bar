#!/usr/bin/env bash
# Build ClaudeWidget.app from the Swift Package and wrap into a macOS .app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
APP_NAME="ClaudeWidget"
APP_DISPLAY="Claude Widget"
BUILD_DIR="$ROOT/dist"
APP_DIR="$BUILD_DIR/$APP_DISPLAY.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

echo "▶ Building Swift package ($CONFIG)…"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "✗ Binary not found: $BIN_PATH"
    exit 1
fi

echo "▶ Assembling .app bundle at ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

# Optional icon — wire up later if Resources/AppIcon.icns exists.
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist" 2>/dev/null || true
fi

# Prefer a stable self-signed identity so Keychain "Always Allow" persists
# across rebuilds. Fall back to ad-hoc if the user hasn't run setup-codesign-cert.sh.
STABLE_CERT="ClaudeWidget Dev"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "\"$STABLE_CERT\""; then
    codesign --force --deep --sign "$STABLE_CERT" "$APP_DIR" >/dev/null 2>&1 || true
    echo "▶ Signed with stable identity \"$STABLE_CERT\"."
else
    codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
    echo "▶ Ad-hoc signed (run scripts/setup-codesign-cert.sh to enable persistent Keychain ACL)."
fi

echo "✓ Built $APP_DIR"
echo
echo "Next:"
echo "  open \"$APP_DIR\""
