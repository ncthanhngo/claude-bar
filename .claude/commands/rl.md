---
description: Cut a signed Claude Bar release end-to-end (bump → build → sign → publish → appcast → push).
argument-hint: [optional new-version] [optional inline notes]
---

You are cutting a signed Claude Bar release. The canonical runbook is the
"Cutting a release (every time)" section of `CLAUDE.md` (gitignored, in
repo root). Follow it end-to-end fully autonomously — do NOT ask the user
anything. Auto-derive any missing inputs. ONLY stop if a preflight check
fails or a destructive step errors out.

Arguments passed in: `$ARGUMENTS`
- First token (optional) = the new version (e.g. `10.4`). No `v` prefix.
  If omitted or empty, AUTO-DERIVE by bumping the minor of the current
  `CFBundleShortVersionString` in `packaging/Info.plist`
  (e.g. `10.3` → `10.4`). Major stays the same.
- Remaining tokens (optional) = inline bullet notes for the release
  description and appcast `<description>`.
  If omitted, AUTO-GENERATE 2-5 bullets by summarizing commits since the
  most recent `v*` tag:

  ```
  PREV=$(git describe --tags --abbrev=0 --match 'v*')
  git log --no-merges --pretty=format:'%s' "$PREV..HEAD"
  ```

  Convert each meaningful commit subject into a short user-facing bullet
  (drop `chore:`, `docs:`, `tools:`-only churn unless they're the only
  changes). Strip conventional-commit prefixes (`feat:`, `fix:`, etc.)
  and rewrite into past-tense, end-user phrasing. Cap at 5 bullets;
  merge near-duplicates. If there are zero meaningful commits, fall back
  to a single bullet: `Maintenance release.`

Derive a one-line release title from the bullets (first bullet, trimmed
to ~60 chars). Use it for both the GitHub release title and the main
commit message.

**NEVER call `AskUserQuestion`.** Make the reasonable call and proceed.

---

## Release channel convention (Stable vs Beta)

Channel is derived purely from the `<NEW>` version string:

- **Stable** — version is a bare integer with NO dot
  (e.g. `10`, `11`, `12`). Major-only versions are public-ready.
- **Beta** — version has a dot
  (e.g. `10.4`, `10.7`, `11.2`). Anything with a minor component is a
  beta / preview build, even if it's been smoke-tested.

This rule is the single source of truth for the channel badge rendered
in the About panel, the GitHub release title prefix, and any future
appcast `<sparkle:channel>` field. Do NOT introduce a third channel
without updating this skill, `CLAUDE.md`, and the AboutTab badge logic
together.

---

## Preflight (fail fast — STOP and report if any check fails)

1. Confirm CWD is the project root (`/Users/soi/dev/02-claude-bar`) and
   `git rev-parse --abbrev-ref HEAD` returns `main`.
2. Working tree must be clean: `git status --short` outputs nothing.
3. New version must be strictly greater than the current
   `CFBundleShortVersionString` in `packaging/Info.plist`.
4. GitHub release must not already exist:
   `gh release view v<NEW> -R ncthanhngo/claude-bar` should print
   `release not found`.
5. Sparkle key intact:
   `widget/.build/artifacts/sparkle/Sparkle/bin/generate_keys -p`
   must print `zkx2LvzfHOZJ0Z5BAcPogHdSx7ClEixTYZqTE4CC/CY=`.
   If it says "No existing signing key found", restore from
   `~/sparkle-private.key` with `generate_keys -f` before continuing.

## Step 1 — Bump `packaging/Info.plist`

Edit three string values:
- `CFBundleVersion` → `<NEW>`
- `CFBundleShortVersionString` → `<NEW>`
- `CFBundleGetInfoString` → replace the existing version inside the
  string (`Claude Bar X.Y — menu-bar manager…`).

Do not touch `CBBuildDate` unless the current value is in the past — keep
it at today's date if it already is.

## Step 1.5 — Update the in-app About panel BEFORE you build

The user must be able to read, inside the running app, exactly what this
release changes — what's new, what was hot-fixed, and what may still be
rough. This MUST be done before `make release` runs, because the notes
are baked into the signed `.app` bundle and cannot be patched
out-of-band afterwards.

Required content for the About → Claude Bar group, this release:

1. **What's new** — 2–5 user-facing bullets. Reuse the same bullets
   derived above for the GitHub release notes; drop anything the user
   can't observe (CI churn, internal refactors that don't change UX).
2. **Hotfixes** — bugs fixed since the previous release. Bullets,
   short, "Fixed …" phrasing. If this release ships no bug fixes
   (pure feature release), write a single bullet `None` rather than
   omitting the section — empty sections look like a missing field.
3. **Known issues** — anything shipping in this build that the user
   should be warned about (a feature that's still flaky, a workaround
   in place, a planned regression). If genuinely none, write `None`.
4. **Channel badge** — derived from the version per the convention
   above: bare integer → `Stable` (green), dotted → `Beta` (orange).

**Writing style — keep About notes SHORT.** The About panel is a
glanceable summary, not changelog prose. Hard rules for the three
`CBRelease*` string keys:

- One sentence per bullet. **Hard cap: ~20 words / ~140 chars per
  bullet.** If a bullet runs longer, split it or cut detail.
- No multi-paragraph entries, no "The previous … now does …" backstory,
  no architectural deep-dives. The user wants "what changed for me",
  not the engineering postmortem.
- Skip implementation details (struct names, function names, file
  paths, socket/handshake mechanics) unless they're part of the
  user-visible API (CLI flag, settings key, MCP tool name).
- The GitHub release notes and the appcast `<description>` CDATA are
  the place for the full story — `CBReleaseWhatsNew` is the TL;DR of
  those, not a copy of them.

If you find yourself writing more than ~3 lines per key, you are
over-writing. Cut.

Storage — add/update these custom keys in `packaging/Info.plist`. They
read like any other CFBundle string, so AboutTab can pull them via
`Bundle.main.infoDictionary` with no extra plumbing:

- `CBReleaseWhatsNew` — newline-separated bullets, no leading bullet
  marker (AboutTab adds its own).
- `CBReleaseHotfixes` — same shape.
- `CBReleaseKnownIssues` — same shape.
- `CBReleaseChannel` — literal `"Stable"` or `"Beta"`. Set explicitly
  rather than re-deriving in Swift, so a future hotfix branch can pin
  the badge without touching the version string.

Then verify `widget/Sources/ClaudeSwapWidget/UI/Tabs/AboutTab.swift`
actually renders these four keys + the channel badge. If it doesn't
(first time running this skill, or someone removed the rendering),
wire it now: replace the hard-coded `"Stable"` capsule with one that
reads `CBReleaseChannel` and tints green for Stable / orange for Beta,
and add a "What's new in this version" sub-section under the version
row that lists the three categories as bulleted text. Keep the
rendering tolerant of empty/missing keys so dev builds without the
keys set still render cleanly.

Build only after the four keys are populated AND AboutTab renders them.
If you skip this step, the user opens About after the update and sees a
stale "Stable" badge with no release notes — that's the bug this step
exists to prevent.

## Step 2 — Build and sign

```
make release
widget/.build/artifacts/sparkle/Sparkle/bin/sign_update release/ClaudeBar.zip
```

Capture from the `sign_update` output:
- `sparkle:edSignature="..."`
- `length="..."`

Verify the freshly built zip is the new version:

```
unzip -p release/ClaudeBar.zip ClaudeBar.app/Contents/Info.plist \
  | plutil -extract CFBundleShortVersionString raw -
```

Also capture `shasum -a 256 release/ClaudeBar.zip` for the post-publish
integrity check.

## Step 3 — Publish GitHub release

```
gh release create v<NEW> release/ClaudeBar.zip \
  -R ncthanhngo/claude-bar \
  --target main \
  --title "v<NEW> — <one-line summary from the bullet notes>" \
  --notes "$(cat <<'EOF'
<bullet notes as markdown>
EOF
)"
```

Then verify the uploaded asset's `digest` matches the local sha256:

```
gh release view v<NEW> -R ncthanhngo/claude-bar --json assets \
  --jq '.assets[] | {name, size, digest}'
```

## Step 4 — Prepend `<item>` to `packaging/appcast.xml`

Insert the new item as the FIRST child of `<channel>` (before the
existing top item). Use this exact shape, substituting values from
steps 1-3:

```xml
    <item>
      <title>Version <NEW></title>
      <sparkle:version><NEW></sparkle:version>
      <sparkle:shortVersionString><NEW></sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <ul>
          <li>…bullet 1…</li>
          <li>…bullet 2…</li>
        </ul>
      ]]></description>
      <pubDate><RFC822 now in +0700></pubDate>
      <enclosure
        url="https://github.com/ncthanhngo/claude-bar/releases/download/v<NEW>/ClaudeBar.zip"
        sparkle:version="<NEW>"
        sparkle:shortVersionString="<NEW>"
        sparkle:edSignature="<SIG FROM STEP 2>"
        length="<LENGTH FROM STEP 2>"
        type="application/octet-stream"/>
    </item>
```

Get the RFC822 timestamp from `LC_ALL=C date "+%a, %d %b %Y %H:%M:%S +0700"`.

## Step 5 — Sync to `gh-pages` + commit/push `main`

```
git fetch origin gh-pages
git worktree add -B gh-pages /tmp/cb-ghpages-wt origin/gh-pages
cp packaging/appcast.xml /tmp/cb-ghpages-wt/appcast.xml
( cd /tmp/cb-ghpages-wt && git add appcast.xml \
    && git -c user.name="Thanh Ngô" -c user.email="nc.thanhngo@gmail.com" \
         commit -m "publish appcast feed for v<NEW>" \
    && git push origin gh-pages )
git worktree remove /tmp/cb-ghpages-wt
```

Then commit on `main` (do NOT use `chore` or `docs` prefixes — match the
existing `release: vX.Y — …` style from `git log`):

```
git add packaging/Info.plist packaging/appcast.xml
git -c user.name="Thanh Ngô" -c user.email="nc.thanhngo@gmail.com" \
    commit -m "release: v<NEW> — <one-line summary>"
git push origin main
```

## Verify

Poll the live appcast until it serves the new version (Pages rebuild is
usually < 60s). Run this as a `Bash` call with `run_in_background: true`
so you get a single notification when done:

```
until rtk proxy curl -s 'https://ncthanhngo.github.io/claude-bar/appcast.xml?cb=v<NEW>' \
  | grep -q '<sparkle:version><NEW></sparkle:version>'; do sleep 5; done
echo "Pages updated with v<NEW>"
```

(`rtk proxy curl` is needed only because the rtk hook caches plain
`curl` output and may show stale content on re-runs.)

Also confirm the release zip URL returns 302:
`curl -sI -o /dev/null -w "%{http_code}\n" https://github.com/ncthanhngo/claude-bar/releases/download/v<NEW>/ClaudeBar.zip`

## Report

Print a compact table with: new version, sha256, signature, GitHub release
URL, Pages build status, and the commit SHA on `main`. List any
unresolved questions at the end, if any.

## Failure handling

If any step fails partway through, STOP and tell the user:
- Which step failed.
- Current state: is `packaging/Info.plist` bumped on disk? are the
  `CBRelease*` notes keys populated? was the GitHub release created?
  was the appcast updated on `main` / on `gh-pages` / live?
- Suggested remediation (e.g. `gh release delete v<NEW>` to roll back
  step 3, `git reset HEAD~` to roll back the main commit, etc.).

Special case — Step 1.5 fails (AboutTab build error after wiring the
new keys): do NOT proceed to `make release`. The signed zip would ship
without the release notes the user expects. Fix the rendering, then
re-run the build.

Do not silently retry destructive operations.
