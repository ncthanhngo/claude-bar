---
phase: 4
title: "Phase 4: Tray app"
status: todo
priority: P1
effort: "1.5d"
dependencies: [3]
---

# Phase 4: Tray app

## Overview
`windows/` Go module building `ClaudeSwap.exe`: a notification-area icon whose menu lists accounts and switches between them by running the bundled `csw.exe`.

## Requirements
- Menu: header (active account), one item per account (check mark on active, "needs login" suffix when dead), separator, "Add current Claude login…", "Rename…", "Remove…", "Start at login" toggle, "Open logs folder", "About / check for updates" (opens GitHub releases), "Quit".
- Switch: disable menu while running, toast "Switched to X" or the error text from `csw`.
- Refresh the menu on open (`csw list --metadata-only`) and every 5 min; `verify` once at start and every 6 h only to flag dead backups (no proactive token rotation).
- Single instance (named mutex `Local\ClaudeSwapTray`); no console window (`-H windowsgui`).
- Dialogs (rename, confirm remove, add-current instructions) via `zenity`.
- Start at login via `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.

## Architecture
```
windows/
  go.mod                      module github.com/soi/claude-swap-widget/windows
  cmd/claudeswap/main.go      tray bootstrap, single instance
  internal/cswclient/         exec csw.exe, JSON DTOs (mirror macOS CswClient)
  internal/tray/              menu build/update, actions
  internal/autostart/         HKCU Run key
  assets/icon.ico, winres/    icon + manifest (DPI aware, asInvoker)
  README.md
```
`csw.exe` ships next to `ClaudeSwap.exe`; resolve it relative to the executable.

## Related Code Files
- Create: everything under `windows/` above; `windows/Makefile` (build both exes with GOOS=windows for amd64 + arm64)

## Implementation Steps
1. cswclient with unit tests (fake exec).
2. Tray menu + switch flow; toasts.
3. Add/rename/remove dialogs.
4. Autostart, single instance, logs folder.
5. Embed icon/manifest with `go-winres`.

## Success Criteria
- [ ] Every menu action works on the VM; no console flashes
- [ ] cswclient tests pass on macOS (`GOOS=windows go vet`) and Windows CI

## Risk Assessment
Tray libraries differ on menu refresh; `fyne.io/systray` supports dynamic items — rebuild the account section on each refresh rather than mutating in place.
