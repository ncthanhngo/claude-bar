---
title: "Windows account swap app"
description: "Tray app for Windows 10/11 that switches the Claude Code account — swap only, reusing the Go csw engine."
status: pending
priority: P2
effort: "5-7d"
tags: [windows, account-swap, tray]
created: 2026-10-26
blockedBy: []
blocks: []
---

# Windows account swap app

## Overview

A small Windows 10/11 tray app (`windows/`) that does one thing: keep several Claude Code logins and switch the active one. No usage bars, auto-swap, web profiles, IDE reload, fan, chat, SSH or iCloud.

Architecture mirrors macOS: the UI never touches credentials; it runs `csw.exe` (the existing Go backend, cross-compiled) and reads its JSON. The swap engine — snapshot outgoing, refresh target under `refresh.lock`, write live, patch `~/.claude.json` `oauthAccount`, rollback, heal — is reused unchanged; only platform adapters are new.

```
windows/ClaudeSwap.exe (tray, Go)  --exec-->  csw.exe (backend, Go, GOOS=windows)
                                                 |-- live:   Claude Code's store (credman or ~/.claude/.credentials.json)
                                                 |-- backup: DPAPI-encrypted files in %APPDATA%\ClaudeSwap\backups
                                                 |-- config: %USERPROFILE%\.claude.json (oauthAccount)
                                                 `-- locks:  LockFileEx on %APPDATA%\ClaudeSwap\{swap,refresh}.lock
```

## Evidence gathered (2026-10-26)

- Claude Code (2.1.310 bundle) has three credential backends: `plaintext` (`<CLAUDE_CONFIG_DIR or ~/.claude>/.credentials.json`), `windows-credman`, and `windows-credman-with-plaintext-fallback`. Credential Manager is used only when the GrowthBook flag `tengu_windows_credman` (cached in `~/.claude.json` → `cachedGrowthBookFeatures`) is true or `CLAUDE_CODE_FORCE_WINDOWS_CREDMAN=1`. **Its Credential Manager target name is not in the macOS bundle** → Phase 1 spike.
- Claude Code re-checks credentials before each token check (plaintext: by `.credentials.json` mtime; keychain/credman: 30 s read cache) and saves refreshed tokens with compare-and-swap, so running sessions follow a swap without restart (verified on macOS; re-verify on Windows in Phase 1).
- `GOOS=windows go build ./...` on `backend/` fails only on `syscall.Flock` (`adapter/lock`) and `syscall.Kill` (`adapter/sessions`). The macOS Keychain adapters compile (they exec `security`) but cannot work on Windows.
- Go `internal/` packages can't be imported from a separate `windows/` module → the tray talks to `csw.exe` over its CLI, like the Swift widget does.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Engine | Reuse `backend/` via build tags + `NewWindowsService` | Same tested swap/refresh/heal logic; no fork |
| UI ↔ engine | Exec `csw.exe --json` | Respects Go `internal/`; mirrors macOS |
| Tray toolkit | Go + `fyne.io/systray`, dialogs via `github.com/ncruces/zenity` (message boxes, no toasts) | One toolchain, cross-compiles from macOS, no .NET runtime |
| Backup storage | DPAPI (`CryptProtectData`, user scope) files, 0600-equivalent ACL | No 2.5 KB Credential Manager blob limit; tied to the Windows user |
| Live storage | Detect: credman target if Claude Code uses it, else `.credentials.json` | Match whichever backend Claude Code is on |
| Adding accounts | "Add current login": user runs `claude /login`, tray adopts the live credential | No OAuth WebView needed; smallest surface |
| Distribution | Portable zip + Inno Setup installer, GitHub Releases | Simple; signing is an open question |

## Phases

| # | Phase | Status |
|---|-------|--------|
| 1 | [Phase 1: Windows spike (verify unknowns)](./phase-01-start.md) | Script ready — run on Windows |
| 2 | [Phase 2: Backend Windows adapters](./phase-02-backend-windows-adapters.md) | Done (code) |
| 3 | [Phase 3: csw swap commands on Windows](./phase-03-csw-swap-commands-on-windows.md) | Done (code) |
| 4 | [Phase 4: Tray app](./phase-04-tray-app.md) | Done (code) |
| 5 | [Phase 5: Packaging and release](./phase-05-packaging-and-release.md) | Done (code; CI builds installer) |
| 6 | [Phase 6: Test matrix Win10 / Win11](./phase-06-test-matrix-win10-win11.md) | Pending — manual |

Implementation notes (deviations from the design above):
- The live store does not hard-code a Credential Manager target: it lists entries starting with `Claude Code`, picks the one holding `claudeAiOauth` (preferring `Claude Code-credentials`), keeps its UTF-8/UTF-16 encoding, and verifies every write by reading it back. When Claude Code is on Credential Manager but the login sits in `.credentials.json`, the file is written.
- **The live adapter is provisional until Phase 1 runs**: target naming per config dir, credential type, encoding and blob size are still unverified. It prefers the newer of Credential Manager and the file, never creates a second Credential Manager entry next to an existing one, and refuses blobs over 2560 bytes.
- No toast notifications: zenity's toasts run PowerShell built from message text (an injection sink) and Windows often drops toasts from unregistered apps. Errors show in message boxes; success shows as the menu's "Active:" line.
- Read-only `list` has a 30 s timeout; `switch`/`add`/`verify`/`rename`/`remove` are never killed (a kill between a token refresh and its save loses the login).
- "(needs login)" is set only for a missing backup or an auth rejection (`invalid_grant`/401), not for network errors at boot.
- `adapter.ClaudeConfigFile` now mirrors Claude Code (legacy `<config dir>\.config.json` if non-empty, else `.claude.json` in `CLAUDE_CONFIG_DIR` or home) on every OS.
- Version for the Windows app lives in `windows/VERSION`; release tags are `win-v<VERSION>`.

Phase 1 gates everything (its findings may change Phase 2's live adapter). 2 → 3 → 4 → 5; 6 runs against the Phase 5 artifact.

## Scope

In: list accounts, show active, switch, add current login, rename, remove, re-login hint when a backup is dead, tray + toast, start at login, single instance, logs.
Out: usage/quota display, auto-swap, web usage, IDE/terminal reload, auto-update (manual "check GitHub" link only), macOS changes beyond build tags.

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Credman target/format differs from guesses | Swap writes nowhere Claude Code reads | Phase 1 spike on a real machine before Phase 2 |
| Claude Code flips backend (flag on/off) between runs | Live written to the wrong store | Detect per operation; write the store Claude Code currently reads; verify by read-back |
| Unsigned exe → SmartScreen "unknown publisher" | Install friction | Document "More info → Run anyway"; open question on an Authenticode cert |
| AV flags Go binaries / DPAPI use | Quarantine | Sign if possible; keep no network except Anthropic OAuth token endpoint |
| Running sessions don't follow swap on Windows | Users must restart `claude` | Phase 1 measures it; if false, show "restart claude" toast (no kill) |

## Success Criteria

- [ ] On Win10 22H2 and Win11 24H2: add 2 accounts, switch A↔B from the tray, `claude` shows the new account (`/status`) without re-login
- [ ] Switching back after Claude Code rotated tokens never asks for `/login`
- [ ] `go test ./...` passes on `windows-latest` CI; macOS build unaffected
- [ ] Installer and portable zip on GitHub Releases

## Open questions

1. Authenticode code-signing certificate: buy one (OV/EV), use Azure Trusted Signing, or ship unsigned?
2. Which Windows machine(s)/VMs are available for Phase 1 and Phase 6 (answered: x64 only — Intel i5-14600 / i5-12400)?
3. Product name for Windows ("Claude Swap"?) and whether it shares accounts/registry format with macOS (no sync either way).
