---
phase: 3
title: "Phase 3: csw swap commands on Windows"
status: todo
priority: P1
effort: "0.5d"
dependencies: [2]
---

# Phase 3: csw swap commands on Windows

## Overview
Expose only the swap subset of `csw` on Windows and make sure each works end-to-end on a real machine.

## Requirements
- Commands: `list --json --metadata-only`, `active --json`, `switch <n> --json`, `add --json` (already adopts the live login as a new account, deduped by email+org — `usecase/add_account.go`), `rename`, `remove`, `verify --json` (dead-backup detection for the "re-login" hint).
- Other subcommands print "not available on Windows" and exit 2.
- JSON shapes identical to macOS so the tray can share DTO definitions.

## Related Code Files
- Modify: `backend/cmd/csw/main.go` (Windows command allowlist)
- Create: `backend/cmd/csw/commands_windows.go` (allowlist)

## Implementation Steps
1. Run existing `csw add` against the Windows live store.
2. Allowlist + friendly error for the rest.
3. Manual run on the VM: add A (current), `claude /login` as B, add B, switch A↔B, verify `~/.claude.json` + live store.

## Success Criteria
- [ ] Manual A↔B switch works from `csw.exe`; `claude /status` shows the switched account
- [ ] Unsupported commands fail cleanly

## Risk Assessment
`add` on an already-registered login refreshes that account's backup instead of creating a second one (existing dedupe) — keep it that way so two backups never share one refresh token.
