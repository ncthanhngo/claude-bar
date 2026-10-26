---
phase: 5
title: "Phase 5: Packaging and release"
status: todo
priority: P2
effort: "1d"
dependencies: [4]
---

# Phase 5: Packaging and release

## Overview
Produce a portable zip and an installer for x64 (arm64 dropped: all target PCs are Intel x86-64), published on GitHub Releases next to the macOS build.

## Requirements
- `windows/Makefile` target `release`: build `ClaudeSwap.exe` + `csw.exe` (amd64), version stamped via `-ldflags`, zip per arch.
- Inno Setup script `windows/installer/claudeswap.iss`: per-user install to `%LOCALAPPDATA%\Programs\ClaudeSwap`, Start-menu shortcut, optional start-at-login, uninstaller that keeps `%APPDATA%\ClaudeSwap` unless the user ticks "remove accounts".
- Code signing per open question (signtool step present but optional).
- Release tag scheme separate from macOS (`win-vX.Y`) so Sparkle's appcast is untouched.

## Implementation Steps
1. Makefile + ldflags version.
2. Inno Setup script; build on Windows CI (`iscc`).
3. GitHub Actions workflow `windows-release.yml` on `win-v*` tags uploading zip + setup.exe.
4. README section: install, SmartScreen note, uninstall.

## Success Criteria
- [x] Tagging `win-v0.1` produces both artifacts on the release
- [x] Fresh Win11 VM installs, runs, uninstalls cleanly

## Risk Assessment
Unsigned installers trigger SmartScreen; document it and revisit signing.
