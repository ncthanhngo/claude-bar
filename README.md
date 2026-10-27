# Claude Bar

A macOS menu-bar app for managing multiple [Claude Code](https://claude.ai/code) accounts. Switch between accounts instantly, auto-swap when quota runs out, track token usage and cost, and keep your IDE and terminal in sync.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)](https://www.apple.com/macos/)
[![Release](https://img.shields.io/github/v/release/ncthanhngo/claude-bar?include_prereleases&sort=semver)](https://github.com/ncthanhngo/claude-bar/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![CI](https://github.com/ncthanhngo/claude-bar/actions/workflows/test.yml/badge.svg)](https://github.com/ncthanhngo/claude-bar/actions/workflows/test.yml)
![Built with Swift & Go](https://img.shields.io/badge/built%20with-Swift%20%2B%20Go-orange)

## Download

| Your computer | App | Get it |
|---|---|---|
| 🍎 **Mac** (macOS 14+) | Claude Bar | `brew install --cask ncthanhngo/tap/claude-bar`, or `ClaudeBar.zip` from the [latest macOS release](https://github.com/ncthanhngo/claude-bar/releases/latest) |
| 🪟 **Windows** 10/11 (x64) | Claude Swap | `ClaudeSwap-<version>-windows-amd64-setup.exe` from the [Windows releases](https://github.com/ncthanhngo/claude-bar/releases?q=win-v&expanded=true) — see [windows/README.md](windows/README.md) |

On the Releases page, macOS releases are titled **macOS · v…** and Windows releases **Windows · Claude Swap …**.

---

## Why Claude Bar?

One Claude Code login at a time means hitting a quota wall mid-session and stopping to re-authenticate by hand. Claude Bar keeps every account a click away in the menu bar, watches your 5-hour usage, and **auto-swaps to a fresh account the moment you run low** — running `claude` sessions pick up the new account on their own, and your IDE can reload too, so you barely notice. It's local-first: credentials live in your macOS Keychain, and nothing leaves your Mac unless you opt in.

---

## Contents

- [Install](#install)
- [Features](#features)
- [Requirements](#requirements)
- [Setup](#setup)
  - [Add accounts](#add-accounts)
  - [IDE reload](#ide-reload--vscode--code-insiders--cursor--windsurf--antigravity)
- [How auto-swap works](#how-auto-swap-works)
- [Command line](#command-line)
- [Windows](#windows)
- [Update](#update)
- [Uninstall](#uninstall)
- [Build from source](#build-from-source)
- [Architecture](#architecture)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)

---

## Install

### Homebrew (recommended)

```bash
brew tap ncthanhngo/tap
brew install --cask claude-bar
```

### Manual

1. Download `ClaudeBar.zip` from [Releases](https://github.com/ncthanhngo/claude-bar/releases/latest)
2. Unzip and drag `ClaudeBar.app` to `/Applications`
3. Launch — the icon appears in your menu bar

---

## Features

- **Multi-account management** — add, rename, and switch Claude Code accounts from the menu bar
- **Credential health** — inactive accounts that can no longer refresh are marked before a broken switch
- **Logins stay alive** — the active account's backup follows the refresh tokens Claude Code rotates, so switching back never asks for `/login`; refreshes are serialised across processes and never spend the running session's token. Events are logged to `~/Library/Logs/ClaudeBar/csw.log`
- **Local only** — no iCloud or cross-Mac sync; every Mac keeps its own logins
- **Usage display** — 5-hour and 7-day quota bars with % and time-until-reset for each account
- **Token usage chart** — Hour / Day / Month histogram of tokens and estimated USD cost across all local Claude Code sessions (CLI + IDE extensions). Click **Details** next to USD to see Anthropic's per-model rate table; rates auto-refresh in the background from a hosted JSON so updated Anthropic pricing flows in without a new release
- **Auto-swap** — automatically switches to a lower-usage account when the active one hits your threshold; gives you a 60-second grace window with a heads-up notification, then swaps regardless of whether `claude` is still running
- **IDE reload** — after a swap, reloads VSCode / Code Insiders / Cursor / Windsurf / Antigravity windows so the extension picks up new credentials (requires Accessibility permission). Reload shortcut is user-configurable (default `⌃⌘R`) and auto-installed into each editor's `keybindings.json`
- **No terminal restarts** — running `claude` sessions (terminal, cmux, GoLand) switch to the new account on their next request (within ~30s); nothing is killed or relaunched
- **Session guard** — warns you if Claude is running before a manual switch; option to force-switch anyway
- **Web-first usage** — each account can link its own embedded claude.ai web profile for usage before falling back to terminal OAuth usage; web sessions stay on this Mac
- **Fan control** — Fan tab shows live fan speed (RPM) and switches between Auto, Max, or a custom speed on Apple Silicon Macs. The first change asks for your admin password once to install a small setuid helper in `/Library/PrivilegedHelperTools`; fans return to Auto when the app quits
- **Themes** — Light, Dark, and Rainbow
- **Icon color** — 11 preset tint colors for the menu bar icon (Settings → General)

---

## Requirements

- macOS 14 (Sonoma) or later
- [Claude Code](https://claude.ai/code) installed, with at least one account logged in (`claude /login`)
- For building from source: Xcode 15+ and Go 1.25+

---

## Setup

### Add accounts

Open **Settings → Accounts → Add account**. Each account needs a separate Claude Code login (`claude /login`).

### IDE reload — VSCode / Code Insiders / Cursor / Windsurf / Antigravity

Enable **Auto-reload IDE after swap** in Settings → General, then click **Grant Access** when the Accessibility prompt appears. Claude Bar will reload supported IDE windows after each swap.

**Reload shortcut.** Default is `⌃⌘R` (Cmd+Ctrl+R) — picked to avoid clashes with VSCode's `⌘R` (Recent Files) and Cursor's `⇧⌘R` (Rerun). Change it in **Settings → General → Reload shortcut** via the key recorder; the new chord is re-applied to every detected editor instantly.

**How injection works.** With *Install shortcut into IDE keybindings.json* enabled (default), Claude Bar adds one entry to each detected editor's `keybindings.json` tagged with `"when": "!falseClaudeBarManaged"`. Toggle off to revert to the legacy `⌘⇧P → Developer: Reload Window` command-palette flow. Zed uses its own keymap and is unaffected. Managed state lives at `~/Library/Application Support/claude-bar/managed-shortcuts.json` and is cleaned up automatically when the shortcut changes or injection is disabled.

## How auto-swap works

1. **Polls usage** every N seconds with adaptive frequency — faster as you approach the threshold
2. Active 5h usage ≥ threshold → notification **"Auto-swap in 60s (X% used)"** — 60-second grace window
3. After the grace, **swaps** to the inactive account with the lowest 5-hour usage (highest subscription tier preferred; accounts at 100% of their 7-day limit are skipped). Running `claude` sessions are never killed — Claude Code re-reads the Keychain and uses the new account from its next request
4. Notification **"Switched to [account]"** — confirmation after the swap completes
5. Triggers **IDE reload** (VSCode / Code Insiders / Cursor / Windsurf / Antigravity) if enabled in Settings

If all inactive accounts are also above the threshold → notification **"All accounts above threshold"**, retry in 10 minutes.

> Auto-swap is triggered by the **5-hour** window only. The 7-day window never triggers a swap, but an account that has used 100% of it is never picked as the target.

---

## Command line

Claude Bar installs a `cbar` shortcut on launch — a symlink to its bundled `csw` backend, placed in the first writable `/opt/homebrew/bin` or `/usr/local/bin`. Use it from any terminal, SSH session, or script to switch accounts by number **or** label:

```bash
cbar list                 # accounts + usage
cbar switch 2             # by number
cbar switch work          # by nickname / email (substring match ok)
cbar switch work --json   # machine-readable output
```

The shortcut points into the app bundle, so it stops working once the app is removed (clean it up with the [uninstall](#uninstall) steps). Building from source? The same binary is at `backend/bin/csw` after `make backend`.

---

## Windows

**Claude Swap** is the Windows 10/11 (x64) companion: a tray app with a popover of accounts and usage, in-app sign-in, login upkeep, and switching for Claude Code (terminal and VS Code) and optionally Claude Desktop. It runs the same `csw` engine built for Windows. Auto-swap, token stats and the Server/Fan tabs stay macOS-only. Get it from the [Windows releases](https://github.com/ncthanhngo/claude-bar/releases?q=win-v&expanded=true); details in [`windows/README.md`](./windows/README.md).

---

## Update

```bash
brew upgrade --cask claude-bar
```

Or manually: download the latest `ClaudeBar.zip` from [Releases](https://github.com/ncthanhngo/claude-bar/releases/latest), unzip, and replace the existing app in `/Applications`.

---

## Uninstall

```bash
brew uninstall --cask claude-bar
```

To also remove all data (accounts, settings, `cbar` shortcut):

```bash
rm -rf "$HOME/Library/Application Support/claude-bar" "$HOME/Library/Application Support/claude-swap-widget"
rm -rf "$HOME/Library/Logs/ClaudeBar"
defaults delete dev.ncthanhngo.claude-bar 2>/dev/null
rm -f /opt/homebrew/bin/cbar /usr/local/bin/cbar    # the cbar CLI shortcut
```

---

## Build from source

Requirements: macOS 14+, Xcode 15+, Go 1.25+

```bash
git clone https://github.com/ncthanhngo/claude-bar.git
cd claude-bar
make install      # builds and copies to /Applications/ClaudeBar.app
```

Other useful targets:

```bash
make app          # build the .app bundle without installing
make backend      # build only the Go backend (csw)
make widget       # build only the SwiftUI menu-bar app
make test         # run the test suite
```

---

## Architecture

Claude Bar follows a clean / hexagonal layout: a SwiftUI menu-bar app (`widget/`) is a thin client that talks to a Go backend (`csw`, `backend/`) over stdin/stdout JSON. The Go side keeps the domain pure and pushes all I/O — Keychain, `~/.claude.json`, the registry, OAuth, sessions — out to adapters behind ports.

See [`docs/architecture.md`](./docs/architecture.md) for the layered diagram and the account-swap transaction.

---

## Contributing

Issues and pull requests are welcome.

1. Build and test locally with `make app` and `make test`.
2. Keep changes focused; match the existing Go and Swift style in the surrounding code.
3. For anything that touches credentials, read [SECURITY.md](./SECURITY.md) first and call out the trust-boundary impact in your PR description.

---

## Security

Claude Bar is local-first and opt-in for any data that leaves your Mac. See [SECURITY.md](./SECURITY.md) for data flows, trust boundaries, and the threat model. Report vulnerabilities to nc.thanhngo@gmail.com with subject prefix `[security]`.

---

## License

[MIT](./LICENSE)
