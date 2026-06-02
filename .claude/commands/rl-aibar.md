---
description: Cut a signed AI Bar release (experimental track) end-to-end.
argument-hint: [optional new-version] [optional inline notes]
---

You are cutting a signed **AI Bar** release — the experimental track, a
SEPARATE app from stable Claude Bar (own bundle id + own appcast feed).
Follow this end-to-end fully autonomously. Do NOT ask the user anything.
ONLY stop if a preflight check fails or a destructive step errors out.
**NEVER call `AskUserQuestion`.**

This mirrors `/rl` (see `.claude/commands/rl.md` + the "Cutting a release"
section of `CLAUDE.md` for the shared mechanics — signing, asset-digest
verification, gh-pages sync). Everything below is the AI-Bar-specific
delta. When a step isn't restated here, do it exactly as `/rl` does.

Arguments passed in: `$ARGUMENTS`
- First token (optional) = new version, no `v` prefix. If omitted,
  AUTO-DERIVE by bumping the MINOR of `CFBundleShortVersionString` in
  **`packaging/Info-aibar.plist`** (e.g. `0.1` → `0.2`).
- Remaining tokens = inline bullet notes. If omitted, AUTO-GENERATE 2-5
  user-facing bullets from commits since the most recent `aibar-v*` tag:
  ```
  PREV=$(git describe --tags --abbrev=0 --match 'aibar-v*' 2>/dev/null)
  git log --no-merges --pretty=format:'%s' "${PREV:+$PREV..}HEAD"
  ```
  (If no `aibar-v*` tag exists yet, summarize commits since branch point.)

## Key differences from stable /rl

| Thing | Stable (/rl) | AI Bar (/rl-aibar) |
|---|---|---|
| Plist | `packaging/Info.plist` | `packaging/Info-aibar.plist` |
| Build | `make release` | `make release DISPLAY_NAME=AIBar INFO_PLIST=packaging/Info-aibar.plist` |
| Zip | `release/ClaudeBar.zip` | `release/AIBar.zip` |
| Git tag | `vX.Y` | `aibar-vX.Y` |
| Release title | `vX.Y — …` | `AI Bar vX.Y — …` |
| Appcast file | `packaging/appcast.xml` | `packaging/appcast-ai-bar.xml` |
| Enclosure URL | `…/download/vX.Y/ClaudeBar.zip` | `…/download/aibar-vX.Y/AIBar.zip` |
| Branch | `main` | `ai-bar` (or a feature branch off it) |
| Channel badge | per version | always `Beta` (keep `CBReleaseChannel` = `Beta`) |

## Preflight (fail fast)

1. Current branch is `ai-bar` (or descends from it) — NOT `main`.
   `/rl-aibar` must never run on `main`.
2. Working tree clean (`git status --short` empty).
3. New version > `CFBundleShortVersionString` in `packaging/Info-aibar.plist`.
4. GitHub release must not already exist:
   `gh release view aibar-v<NEW> -R ncthanhngo/claude-bar` → `release not found`.
5. Sparkle key intact (same check as /rl — pubkey
   `zkx2LvzfHOZJ0Z5BAcPogHdSx7ClEixTYZqTE4CC/CY=`). AI Bar signs with the
   SAME key as stable.

## Steps

1. **Bump `packaging/Info-aibar.plist`**: `CFBundleVersion`,
   `CFBundleShortVersionString` → `<NEW>`; update the version inside
   `CFBundleGetInfoString` (`AI Bar X.Y — …`). Set `CBBuildDate` to today
   if it's in the past.

1.5. **Update the About panel keys in `packaging/Info-aibar.plist`** —
   `CBReleaseWhatsNew` / `CBReleaseHotfixes` / `CBReleaseKnownIssues`
   (same short style as /rl, ≤~20 words per bullet). Keep
   `CBReleaseChannel` = `Beta`. AboutTab already renders these.

   **FIRST RELEASE ONLY:** flip `SUEnableAutomaticChecks` in
   `Info-aibar.plist` from `<false/>` to `<true/>` (the empty-feed error
   guard is no longer needed once a real item is live).

2. **Build + sign:**
   ```
   make release DISPLAY_NAME=AIBar INFO_PLIST=packaging/Info-aibar.plist
   widget/.build/artifacts/sparkle/Sparkle/bin/sign_update release/AIBar.zip
   ```
   Capture `sparkle:edSignature` + `length`. Verify zip version:
   ```
   unzip -p release/AIBar.zip 'AIBar.app/Contents/Info.plist' \
     | plutil -extract CFBundleShortVersionString raw -
   ```
   Also capture `shasum -a 256 release/AIBar.zip`.

3. **Publish GitHub release** (tag `aibar-v<NEW>`, same repo):
   ```
   gh release create aibar-v<NEW> release/AIBar.zip \
     -R ncthanhngo/claude-bar --target ai-bar \
     --title "AI Bar v<NEW> — <one-line summary>" \
     --notes "<bullets as markdown>"
   ```
   Verify uploaded asset digest matches the local sha256.

4. **Prepend `<item>` to `packaging/appcast-ai-bar.xml`** as the first
   child of `<channel>`. Same shape as /rl's item but:
   - enclosure `url` → `https://github.com/ncthanhngo/claude-bar/releases/download/aibar-v<NEW>/AIBar.zip`
   - `<title>AI Bar <NEW></title>`
   RFC822 pubDate from `LC_ALL=C date "+%a, %d %b %Y %H:%M:%S +0700"`.

5. **Sync to gh-pages + commit/push `ai-bar`:**
   ```
   git fetch origin gh-pages
   git worktree add -B gh-pages /tmp/cb-ghpages-wt origin/gh-pages
   cp packaging/appcast-ai-bar.xml /tmp/cb-ghpages-wt/appcast-ai-bar.xml
   ( cd /tmp/cb-ghpages-wt && git add appcast-ai-bar.xml \
       && git -c user.name="Thanh Ngô" -c user.email="nc.thanhngo@gmail.com" \
            commit -m "publish AI Bar appcast feed for v<NEW>" \
       && git push origin gh-pages )
   git worktree remove /tmp/cb-ghpages-wt
   ```
   Then commit on `ai-bar` (NOT main):
   ```
   git add packaging/Info-aibar.plist packaging/appcast-ai-bar.xml
   git -c user.name="Thanh Ngô" -c user.email="nc.thanhngo@gmail.com" \
       commit -m "release: AI Bar v<NEW> — <one-line summary>"
   git push origin ai-bar
   ```

## Verify

Poll the live AI Bar feed until it serves `<NEW>`:
```
until rtk proxy curl -s 'https://ncthanhngo.github.io/claude-bar/appcast-ai-bar.xml?cb=v<NEW>' \
  | grep -q '<sparkle:version><NEW></sparkle:version>'; do sleep 5; done
```
Confirm the zip URL returns 302:
`curl -sI -o /dev/null -w "%{http_code}\n" https://github.com/ncthanhngo/claude-bar/releases/download/aibar-v<NEW>/AIBar.zip`

## Report

Compact table: AI Bar version, sha256, signature, release URL, Pages
status, commit SHA on `ai-bar`. List any unresolved questions at the end.
