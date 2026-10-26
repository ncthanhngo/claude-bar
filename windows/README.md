# Claude Swap for Windows

Windows 10/11 tray app that keeps several Claude Code logins and switches the
active one. Scope is account switching only — no usage display, auto-swap,
web profiles or IDE reload (those stay macOS-only in Claude Bar).

Status: **built, not yet tested on real Windows.** Design and test checklist:
[`docs/plan/plan.md`](docs/plan/plan.md).

## How it works

`ClaudeSwap.exe` (notification-area icon) never touches credentials. It runs
the bundled `csw.exe` — the same Go engine as the macOS app, built for
Windows — and reads its JSON. `csw` snapshots the outgoing login, refreshes
the target under a cross-process lock, writes it where Claude Code reads it
(Windows Credential Manager or `%USERPROFILE%\.claude\.credentials.json`,
detected each time and verified by read-back) and patches `oauthAccount` in
`%USERPROFILE%\.claude.json`. Running `claude` sessions pick up the new
account on their next request. Saved accounts are DPAPI-encrypted files in
`%APPDATA%\ClaudeSwap`; the log is `%LOCALAPPDATA%\ClaudeSwap\logs\csw.log`.
Nothing syncs between machines.

## Use

1. In a terminal: `claude /login` with your first account.
2. Tray menu → **Add current Claude login…**
3. `claude /login` with the next account, then **Add current Claude login…** again.
4. Click an account in the tray menu to switch to it.

## Build (any OS, Go 1.25+)

```sh
cd windows
make build   # dist/windows-{amd64,arm64}/{ClaudeSwap.exe,csw.exe}
make zip     # portable zips
make test    # unit tests (tray client + backend)
```

The installer is built on Windows with Inno Setup:
`iscc /DAppVersion=0.1.0 /DArch=amd64 installer\claudeswap.iss`.
Pushing a tag `win-v<VERSION>` (matching `VERSION`) makes CI publish zips and
installers for x64 and ARM64. Builds are unsigned: SmartScreen may show
*More info → Run anyway*.

## Testing on a Windows machine

1. Clone the repo, install Go 1.25+, then `cd windows; make test` (or the two
   `go test ./...` commands) — this exercises Credential Manager-free code,
   DPAPI and file locks on real Windows.
2. Run `powershell -ExecutionPolicy Bypass -File spike\inspect-claude-credentials.ps1`
   and record the output (no tokens are printed) — it tells which store
   Claude Code uses on that PC.
3. Follow the checklist in
   [`docs/plan/phase-06-test-matrix-win10-win11.md`](docs/plan/phase-06-test-matrix-win10-win11.md).

## Layout

```
cmd/claudeswap/       tray entry point (+ generated icon/manifest .syso)
internal/cswclient/   runs csw.exe, decodes JSON
internal/tray/        menu, dialogs, notifications
internal/winutil/     single instance, start at login, shell open
installer/            Inno Setup script
spike/                diagnostics for a new machine
```
