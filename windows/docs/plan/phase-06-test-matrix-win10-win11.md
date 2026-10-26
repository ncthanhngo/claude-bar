---
phase: 6
title: "Phase 6: Test matrix Win10 / Win11"
status: todo
priority: P1
effort: "0.5d"
dependencies: [5]
---

# Phase 6: Test matrix Win10 / Win11

## Overview
Manual acceptance on the supported OS versions with real Claude accounts.

## Requirements
Matrix: Windows 10 22H2 x64, Windows 11 23H2 x64, Windows 11 24H2 x64 (x64 only — no ARM machines); each with Claude Code in both credential modes if the flag can be forced (`CLAUDE_CODE_FORCE_WINDOWS_CREDMAN=1`).

## Implementation Steps (checklist per machine)
1. Install from setup.exe; tray icon appears; no console window.
2. Add current login A; `claude /login` B; add B.
3. Switch A→B with a running `claude`; after ~30 s a prompt runs as B (`/status`), no restart.
4. Leave B active overnight (Claude Code rotates the token); switch back to A, then to B → no `/login` prompt.
5. Rename, remove, start-at-login, reboot.
6. Corrupt A's backup (delete file) → menu shows "needs login".
7. Uninstall; accounts kept unless chosen.

## Success Criteria
- [ ] All steps pass on every matrix row; findings logged in this file

## Risk Assessment
Needs two real Claude accounts per tester; overnight step needs a machine left running.
