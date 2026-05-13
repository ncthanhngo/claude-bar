#!/usr/bin/env bash
# Cut a new release: build DMG, refresh Casks/claude-bar.rb, optionally push a
# GitHub release with the DMG attached.
#
# Usage: bash scripts/release.sh <version>           # eg. 0.7.3
#        bash scripts/release.sh <version> --draft   # create the gh release as draft
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
DRAFT_FLAG="${2:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <version> [--draft]"
    exit 1
fi

PLIST="$ROOT/Resources/Info.plist"
CASK="$ROOT/Casks/claude-bar.rb"
DMG="$ROOT/ClaudeWidget-$VERSION.dmg"

echo "▶ Bumping Info.plist to $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
# CFBundleVersion is monotonic — bump from current.
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST" 2>/dev/null || echo "0")
NEW_BUILD=$((CURRENT_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"

echo "▶ Building DMG"
rm -f "$ROOT"/ClaudeWidget-*.dmg
bash "$ROOT/scripts/package-dmg.sh" "$VERSION" >/dev/null

if [[ ! -f "$DMG" ]]; then
    echo "✗ DMG not produced: $DMG"
    exit 1
fi

SHA256=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "▶ DMG sha256: $SHA256"

echo "▶ Updating $CASK"
# version + sha256 fields
sed -i '' "s/^  version \".*\"/  version \"$VERSION\"/" "$CASK"
sed -i '' "s/^  sha256 \".*\"/  sha256 \"$SHA256\"/" "$CASK"

echo "▶ Committing version bump"
git add "$PLIST" "$CASK"
git commit -m "release: v$VERSION" >/dev/null || echo "  (nothing to commit)"

# Tag + push
git tag -a "v$VERSION" -m "v$VERSION" 2>/dev/null || true
git push --follow-tags origin HEAD 2>/dev/null || echo "  (push skipped — no remote or not configured)"

# Create GitHub release with DMG
if command -v gh >/dev/null 2>&1; then
    EXTRA=""
    [[ "$DRAFT_FLAG" == "--draft" ]] && EXTRA="--draft"
    echo "▶ Creating GitHub release v$VERSION"
    gh release create "v$VERSION" "$DMG" \
        --title "v$VERSION" \
        --notes "Automated release. See README for install instructions." \
        $EXTRA \
        || echo "  (gh release create failed — release may already exist)"
else
    echo "  (skip gh release — install GitHub CLI to automate this)"
fi

echo
echo "✓ v$VERSION released"
echo "  DMG  : $DMG"
echo "  Cask : $CASK ($SHA256)"
