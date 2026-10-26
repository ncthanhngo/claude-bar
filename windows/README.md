# Claude Swap for Windows

Windows 10/11 tray app that keeps several Claude Code logins and switches the
active one. Scope is account switching only — no usage display, auto-swap,
web profiles or IDE reload (those stay macOS-only in Claude Bar).

Status: **planned, not built yet.** The implementation plan lives in
[`docs/plan/plan.md`](docs/plan/plan.md).

## Design in one paragraph

`ClaudeSwap.exe` (Go, notification-area icon) never touches credentials. It
runs the bundled `csw.exe` — the same Go engine as the macOS app, built with
`GOOS=windows` and Windows adapters — and reads its JSON. `csw` snapshots the
outgoing login, refreshes the target under a cross-process lock, writes it to
the store Claude Code reads (Windows Credential Manager or
`%USERPROFILE%\.claude\.credentials.json`, detected at runtime), and patches
`oauthAccount` in `%USERPROFILE%\.claude.json`. Account backups are
DPAPI-encrypted files under `%APPDATA%\ClaudeSwap`. Nothing syncs between
machines.

## Planned layout

```
windows/
  cmd/claudeswap/   tray entry point
  internal/         cswclient, tray, autostart
  assets/           icon, manifest
  installer/        Inno Setup script
  spike/            Phase 1 verification scripts
  Makefile          GOOS=windows builds (amd64, arm64)
```
