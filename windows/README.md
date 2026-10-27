# Claude Swap for Windows

Windows 10/11 tray app that keeps several Claude accounts and switches the
active one — for Claude Code (terminal and VS Code) and, optionally, Claude
Desktop. Auto-swap, the Server/Fan/Netbird tabs and token stats stay
macOS-only in Claude Bar.

Status: used on Windows 11 (x64). Design and test checklist:
[`docs/plan/plan.md`](docs/plan/plan.md).

## Features

- **Popover** (left-click the tray icon), like the macOS one: accounts with
  5h / 7d / per-model usage bars and reset countdowns, plan badge, click a row
  to switch, ⋯ per row for rename / remove / Claude Desktop. Right-click keeps
  the classic menu.
- **Sign in inside the app** — **+ Sign in account** opens claude.ai in a
  WebView2 window; the account is saved when sign-in finishes. No terminal
  needed. A browser + pasted code is the fallback without WebView2.
- **Keeps logins alive** — expired tokens of inactive accounts are refreshed
  (verify every 6 h, on popover open, on switch); the active account's
  rotated login is saved every 15 min (`csw snapshot-active`, which refuses
  when Claude Code is logged in to another account).
- **Recovers lost logins** — an account flagged *needs login* is signed back
  in in the background with its own claude.ai session (hidden WebView2,
  auto-Authorize; at most 3 tries, 5 min apart, 5 grants/hour — same limits
  as macOS). Otherwise **Sign in again** on its row.
- **Reload VS Code after switching** — Claude sessions started by an editor
  extension (`entrypoint` ≠ `cli`) are restarted so they use the new account;
  a session busy answering is restarted once it is idle.
- **Switch Claude Desktop too** — save Desktop's sign-in once per account
  (⋯ on the row → *Save Claude Desktop sign-in here…*); switching then closes
  Desktop, swaps its sign-in (cookies / local storage / IndexedDB only — MCP
  config and settings are shared) and reopens it.

## How it works

`ClaudeSwap.exe` (notification-area icon) never touches Claude Code
credentials. It runs the bundled `csw.exe` — the same Go engine as the macOS
app, built for Windows — and reads its JSON. `csw` snapshots the outgoing
login, refreshes the target under a cross-process lock, writes it where
Claude Code reads it (Windows Credential Manager or
`%USERPROFILE%\.claude\.credentials.json`, detected each time and verified by
read-back) and patches `oauthAccount` in `%USERPROFILE%\.claude.json`.
Terminal `claude` sessions pick up the new account on their next request.

In-app sign-in uses Claude Code's own OAuth client: `csw login-url` makes the
PKCE authorize URL, the sign-in window (`ClaudeSwap.exe --sign-in`, its own
short-lived process) returns the code, and `csw add-oauth-code` exchanges it
and saves the account — tokens stay inside `csw` and travel on stdin.

Files:

| Path | What |
|---|---|
| `%APPDATA%\ClaudeSwap` | saved accounts (DPAPI-encrypted), `tray.json` settings |
| `%APPDATA%\ClaudeSwap\desktop` | saved Claude Desktop sign-ins (DPAPI-encrypted) |
| `%LOCALAPPDATA%\ClaudeSwap\profiles` | per-account claude.ai web sessions (for recovery) |
| `%LOCALAPPDATA%\ClaudeSwap\logs` | `csw.log`, `tray.log` (clicks and outcomes, no secrets) |

Nothing syncs between machines.

## Use

1. Click the tray icon → **+ Sign in account**, sign in to Claude, repeat for
   each account. (Or `claude /login` in a terminal, then **Add current Claude
   Code login**.)
2. Click an account in the popover to switch to it.
3. Optional, Claude Desktop: sign Desktop in to an account, then ⋯ on that
   account's row → **Save Claude Desktop sign-in here…**. Repeat per account.

## Build (any OS, Go 1.25+)

> **Chỉ build bản amd64 (x64).** Các máy Windows của mình đều chạy chip Intel
> x86-64 (i5-14600, i5-12400…), nên build và release không còn bản arm64.
> File cần lấy: `windows-amd64` / `*-windows-amd64.zip` / `*-windows-amd64-setup.exe`.

```sh
cd windows
make build   # dist/windows-amd64/{ClaudeSwap.exe,csw.exe}
make zip     # portable zip
make test    # unit tests (tray client + backend)
```

The installer is built on Windows with Inno Setup:
`iscc /DAppVersion=<VERSION> installer\claudeswap.iss`.
Pushing a tag `win-v<VERSION>` (matching `VERSION`) makes CI publish the x64
zip and installer. Builds are unsigned: SmartScreen may show
*More info → Run anyway*, and Smart App Control (if on) blocks them.

## Testing on a Windows machine

1. Clone the repo, install Go 1.25+, then `cd windows; make test` (or the two
   `go test ./...` commands) — this exercises DPAPI, file locks, the Desktop
   sign-in swap and the IDE session filter on real Windows.
2. Run `powershell -ExecutionPolicy Bypass -File spike\inspect-claude-credentials.ps1`
   and record the output (no tokens are printed) — it tells which store
   Claude Code uses on that PC.
3. Follow the checklist in
   [`docs/plan/phase-06-test-matrix-win10-win11.md`](docs/plan/phase-06-test-matrix-win10-win11.md).

## Layout

```
cmd/claudeswap/       tray entry point (+ generated icon/manifest .syso)
internal/cswclient/   runs csw.exe, decodes JSON
internal/tray/        tray menu, popover (popover.html in WebView2), sign-in
                      window, background recovery, IDE reload, Claude Desktop
internal/winutil/     single instance, start at login, shell open
installer/            Inno Setup script
spike/                diagnostics for a new machine
```
