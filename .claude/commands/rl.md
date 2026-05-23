---
description: Cut a signed Claude Bar release end-to-end (bump → build → sign → publish → appcast → push).
argument-hint: <new-version> [optional inline notes]
---

You are cutting a signed Claude Bar release. The canonical runbook is the
"Cutting a release (every time)" section of `CLAUDE.md` (gitignored, in
repo root). Follow it end-to-end without asking for confirmation between
mechanical steps. ONLY ask if something is genuinely ambiguous or a check
fails.

Arguments passed in: `$ARGUMENTS`
- First token = the new version (e.g. `10.4`). No `v` prefix in the
  argument; commands and tags use `vX.Y`.
- Remaining tokens (if any) = inline bullet notes to put in the release
  description and appcast `<description>`.
- If only the version is provided, ask the user for 2-5 bullet notes via
  the `AskUserQuestion` tool before proceeding.

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
- Current state: is `packaging/Info.plist` bumped on disk? was the
  GitHub release created? was the appcast updated on `main` / on
  `gh-pages` / live?
- Suggested remediation (e.g. `gh release delete v<NEW>` to roll back
  step 3, `git reset HEAD~` to roll back the main commit, etc.).

Do not silently retry destructive operations.
