---
phase: 2
title: "Phase 2: Backend Windows adapters"
status: todo
priority: P1
effort: "2d"
dependencies: [1]
---

# Phase 2: Backend Windows adapters

## Overview
Make `backend/` build and run on Windows by adding platform adapters behind build tags; macOS behaviour and files stay byte-for-byte the same.

## Requirements
- `GOOS=windows go build ./...` and `go test ./...` pass; macOS build/tests unchanged.
- No new behaviour in usecases; only adapters + a Windows composition root.

## Architecture
| Port | macOS (existing) | Windows (new) |
|---|---|---|
| `FileLock` | `syscall.Flock` | `lock/file_lock_windows.go`: `windows.LockFileEx` (exclusive, fail-immediately, poll 50 ms, honour ctx) |
| Session liveness | `syscall.Kill(pid,0)` | `sessions/alive_windows.go`: `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` + `GetExitCodeProcess == STILL_ACTIVE` |
| `LiveCredentialStore` | Keychain `Claude Code-credentials` | `wincreds/live_store.go`: detect backend per call (Phase 1 rules); plaintext → atomic write of `.credentials.json` (temp + `MoveFileEx` replace) preserving ACL; credman → `CredReadW/CredWriteW` with the target from Phase 1 |
| `BackupCredentialStore` (+`ReadFresh`) | Keychain `csw-backup:N:email` | `wincreds/backup_store.go`: DPAPI-protected file `%APPDATA%\ClaudeSwap\backups\<N>-<sha256(email)[:12]>.bin`; `ReadFresh` = uncached read |
| Paths | `~/Library/...` | `paths_windows.go`: data `%APPDATA%\ClaudeSwap`, log `%LOCALAPPDATA%\ClaudeSwap\logs\csw.log`; `ClaudeConfigDir` keeps `CLAUDE_CONFIG_DIR` / `%USERPROFILE%\.claude` |
| Composition root | `NewMacOSService` | `wire_windows.go`: `NewWindowsService` (no MCP/chat/SSH stores) |

Split `paths.go` / `wire.go` into `_darwin.go` + `_windows.go` where they diverge; keep shared helpers in untagged files.

## Related Code Files
- Create: `backend/internal/adapter/lock/file_lock_windows.go`, `backend/internal/adapter/sessions/alive_windows.go` (+ `_unix.go` twin), `backend/internal/adapter/wincreds/{live_store,backup_store,dpapi,credman}.go` + tests, `backend/internal/adapter/paths_windows.go`, `backend/internal/usecase/wire_windows.go`
- Modify: `file_lock.go` → `file_lock_unix.go` (`//go:build !windows`), `paths.go`, `wire.go` (`//go:build darwin`), `backend/cmd/csw/main.go` (pick root by GOOS)
- CI: add `windows-latest` job running `go test ./...` in `backend/`

## Implementation Steps
1. Build tags for lock + sessions; `GOOS=windows go build ./...` green.
2. DPAPI backup store with tests (round-trip, wrong-user fails, `ReadFresh` bypasses cache).
3. Live store per Phase 1 findings; tests against a temp `CLAUDE_CONFIG_DIR` (plaintext) and a test target name (credman).
4. `NewWindowsService`; wire into `csw` main.
5. Windows CI job.

## Success Criteria
- [x] Windows CI green; macOS `make release` unchanged
- [x] Usecase tests (swap, refresh lock, heal) run unmodified on Windows

## Risk Assessment
- Atomic replace of `.credentials.json` while Claude Code reads it: use `MoveFileEx(MOVEFILE_REPLACE_EXISTING)`; Claude Code tolerates a missing/locked file on read (treats as absent → must not happen mid-swap → write temp in same dir, then replace).
- `LockFileEx` locks are per-handle: create a fresh handle per Acquire (same rule as macOS flock, see FileLock note).
