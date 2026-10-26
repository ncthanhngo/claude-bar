---
phase: 1
title: "Phase 1: Windows spike (verify unknowns)"
status: todo
priority: P1
effort: "0.5d"
dependencies: []
---

# Phase 1: Windows spike (verify unknowns)

## Overview
Answer, on a real Windows 10/11 machine with Claude Code installed, the questions the design depends on. No product code; output is a short findings note appended to this file.

## Requirements
- Which backend this Claude Code uses: check `%USERPROFILE%\.claude.json` → `cachedGrowthBookFeatures.tengu_windows_credman`, env `CLAUDE_CODE_FORCE_WINDOWS_CREDMAN`, existence of `%USERPROFILE%\.claude\.credentials.json`, and `cmdkey /list | findstr /i claude`.
- If Credential Manager: exact target name, type (generic), user name field, blob encoding (UTF-16 vs UTF-8 JSON), blob size; whether it splits large blobs.
- `.credentials.json` JSON shape (expect `{"claudeAiOauth":{accessToken,refreshToken,expiresAt,scopes,subscriptionType}}`) and file ACL.
- Where Claude Code writes the refresh lock (`~/.claude/.oauth_refresh.lock`) and session files (`~/.claude/sessions/*.json`) on Windows.
- Live-session adoption: with two accounts, start `claude`, replace the live credential + `oauthAccount` by hand (PowerShell script), send a prompt after ~30 s, run `/status` → which account?

## Implementation Steps
1. Install Claude Code on the test VM; `claude /login` with account A.
2. Run the checks above; capture outputs (redact tokens — record lengths/hashes only).
3. Write `windows/spike/swap-by-hand.ps1` that does a manual A→B swap for the adoption test.
4. Record findings + decisions (credman vs plaintext adapter) here; update Phase 2 if anything differs.

## Success Criteria
- [ ] Backend, target name/format and adoption behaviour documented with evidence
- [ ] Phase 2 live-adapter design confirmed or amended

## Risk Assessment
Findings may show the credman backend needs a native (cgo-free) `CredReadW/CredWriteW` binding with UTF-16 blobs — covered by `golang.org/x/sys/windows`/`github.com/danieljoos/wincred`.
