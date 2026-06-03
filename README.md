# Claude Bar

A macOS menu-bar app for managing multiple [Claude Code](https://claude.ai/code) accounts. Switch between accounts instantly, auto-swap when quota runs out, track token usage and cost, and keep your IDE and terminal in sync.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)](https://www.apple.com/macos/)
[![Release](https://img.shields.io/github/v/release/ncthanhngo/claude-bar?include_prereleases&sort=semver)](https://github.com/ncthanhngo/claude-bar/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![CI](https://github.com/ncthanhngo/claude-bar/actions/workflows/test.yml/badge.svg)](https://github.com/ncthanhngo/claude-bar/actions/workflows/test.yml)
![Built with Swift & Go](https://img.shields.io/badge/built%20with-Swift%20%2B%20Go-orange)

---

## Why Claude Bar?

One Claude Code login at a time means hitting a quota wall mid-session and stopping to re-authenticate by hand. Claude Bar keeps every account a click away in the menu bar, watches your 5-hour usage, and **auto-swaps to a fresh account the moment you run low** — then reloads your IDE and restarts your terminal session so you barely notice. It's local-first: credentials live in your macOS Keychain, and nothing leaves your Mac unless you opt in.

---

## Contents

- [Install](#install)
- [Features](#features)
- [Requirements](#requirements)
- [Setup](#setup)
  - [Add accounts](#add-accounts)
  - [Auto-restart terminal sessions](#auto-restart-terminal-sessions)
  - [IDE reload](#ide-reload--vscode--code-insiders--cursor--windsurf--antigravity)
  - [Cmux pane relaunch](#cmux-pane-relaunch)
  - [Local MCP connectors](#local-mcp-connectors-optional)
- [How auto-swap works](#how-auto-swap-works)
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
- **Usage display** — 5-hour and 7-day quota bars with % and time-until-reset for each account
- **Token usage chart** — Hour / Day / Month histogram of tokens and estimated USD cost across all local Claude Code sessions (CLI + IDE extensions). Click **Details** next to USD to see Anthropic's per-model rate table; rates auto-refresh in the background from a hosted JSON so updated Anthropic pricing flows in without a new release
- **Auto-swap** — automatically switches to a lower-usage account when the active one hits your threshold; gives you a 60-second grace window with a heads-up notification, then swaps regardless of whether `claude` is still running
- **IDE reload** — after a swap, reloads VSCode / Code Insiders / Cursor / Windsurf / Antigravity windows so the extension picks up new credentials (requires Accessibility permission). Reload shortcut is user-configurable (default `⌃⌘R`) and auto-installed into each editor's `keybindings.json`
- **CLI auto-restart** — sends SIGINT to running `claude` sessions; use with the bundled `claude-watch` wrapper to auto-restart in your terminal
- **Session guard** — warns you if Claude is running before a manual switch; option to force-switch anyway
- **Web-first usage** — each account can link its own embedded claude.ai web profile for usage before falling back to terminal OAuth usage; web sessions sync separately through iCloud Keychain by account email
- **Local MCP connectors** — share one set of Slack / ClickUp / Google / GitHub / GitLab / Bitwarden tokens across accounts and reach them from Claude Code through a local stdio gateway (see [below](#local-mcp-connectors-optional))
- **Themes** — Light, Dark, and Rainbow
- **Icon color** — 11 preset tint colors for the menu bar icon (Settings → General)

---

## Requirements

- macOS 14 (Sonoma) or later
- [Claude Code](https://claude.ai/code) installed, with at least one account logged in (`claude /login`)
- For building from source: Xcode 15+ and Go 1.23+

---

## Setup

### Add accounts

Open **Settings → Accounts → Add account**. Each account needs a separate Claude Code login (`claude /login`).

### Auto-restart terminal sessions

**Not required for swaps to take effect** — running `claude` sessions pick up the new account credentials automatically, without a restart (verify with `/usage` mid-session). Enable **Auto-kill CLI sessions** in Settings → General only if you prefer sessions to restart as fresh processes after a swap. Claude Bar automatically installs `claude-watch` and adds the shell alias on first launch — no manual steps needed. When a swap happens, your terminal session (including GoLand's integrated terminal) then restarts automatically.

### IDE reload — VSCode / Code Insiders / Cursor / Windsurf / Antigravity

Enable **Auto-reload IDE after swap** in Settings → General, then click **Grant Access** when the Accessibility prompt appears. Claude Bar will reload supported IDE windows after each swap.

**Reload shortcut.** Default is `⌃⌘R` (Cmd+Ctrl+R) — picked to avoid clashes with VSCode's `⌘R` (Recent Files) and Cursor's `⇧⌘R` (Rerun). Change it in **Settings → General → Reload shortcut** via the key recorder; the new chord is re-applied to every detected editor instantly.

**How injection works.** With *Install shortcut into IDE keybindings.json* enabled (default), Claude Bar adds one entry to each detected editor's `keybindings.json` tagged with `"when": "!falseClaudeBarManaged"`. Toggle off to revert to the legacy `⌘⇧P → Developer: Reload Window` command-palette flow. Zed uses its own keymap and is unaffected. Managed state lives at `~/Library/Application Support/claude-bar/managed-shortcuts.json` and is cleaned up automatically when the shortcut changes or injection is disabled.

### Cmux pane relaunch

If you run `claude` inside a [cmux](https://cmux.com/) terminal pane, Claude Bar automatically resumes the conversation under the new account after each swap. It reads cmux's hook state at `~/.cmuxterm/claude-hook-sessions.json`, then for every active Claude pane sends `Ctrl-C` followed by `claude --resume <sessionId>` via `cmux send-key` / `cmux send`. No toggle required.

Requires `cmux hooks setup` (so cmux tracks sessions) and the `cmux` CLI on `PATH`. Panes that pin an isolated `CLAUDE_CONFIG_DIR` (e.g. `~/.codex-accounts/claude/<id>/`) are intentionally skipped — claude-bar's global credential swap does not reach them, and merging the two account systems would defeat the isolation. When no cmux panes are active this integration is a silent no-op.

### Local MCP connectors (optional)

Claude Bar can keep one shared set of Slack, ClickUp, and Google Workspace tokens for every account on this Mac, plus optional per-account overrides. Claude Code reaches them through a local stdio gateway. Tokens stay in the macOS Keychain locally; if iCloud Sync is enabled, they are copied only into the passphrase-encrypted Claude Bar iCloud bundle so another Mac signed into the same Apple ID can restore them into its own Keychain. Switching accounts in the menu bar swaps to that account's override when present; otherwise it uses the shared connector — no Claude Code restart required.

1. Open **Settings → Local MCP**.
2. Click **Install** to wire `claude-bar-mcp` into `~/.claude.json`.
3. In **Shared for all accounts**, click **Connect** next to each service you want to use across all Claude Bar accounts. Use per-account rows only when an account should override the shared connector.
   - Slack/ClickUp/GitHub/GitLab: paste a personal user token (Slack `xoxp-…`/`xoxe-…`, ClickUp `pk_…`, GitHub `ghp_…`/`github_pat_…`, GitLab PAT). Slack bot tokens (`xoxb-…`) are not supported because Slack search requires a user token. The token is piped to `csw` over stdin and never appears in argv or shell history.
   - Google Workspace: enable Drive, Calendar, Gmail, and Sheets APIs in Google Cloud, paste your OAuth Desktop client ID/secret or import the downloaded JSON file, then click **Open browser to connect**. PKCE (S256) is still used. Existing Google connectors created before Sheets/share support must be disconnected and reconnected once so Google grants the newer `spreadsheets` and `drive.file` scopes.
4. Restart Claude Code once so it picks up the new MCP server. After that, switching Claude Bar accounts is hot — Claude Code keeps running.

**Tools exposed.** The gateway registers more than 90 tools, named `cb_<service>_…` and grouped by service:

| Service | Tools | Examples |
|---|---|---|
| Slack | 9 | list channels, search messages, read threads, post message, reply |
| ClickUp | 15 | list/search/get tasks, comments, create & update tasks, assign |
| GitHub | 28 | issues, PRs, reviews, file/commit reads, CI runs, plus gated writes (open PR, merge, labels) |
| GitLab | 19 | MRs, issues, file reads, pipelines, plus gated writes (open/approve/merge MR) |
| Google Drive | 6 | search files, read docs, file metadata, download, share |
| Google Calendar | 4 | list calendars, list events, get event, free/busy |
| Gmail | 4 | search messages, get message/thread, list labels |
| Google Sheets | 4 | create spreadsheet, create from CSV, append/update values |
| Bitwarden | 3 | search items, get item, list folders |
| SSH | 4 | list hosts (from `~/.ssh/config`), exec, read file, tail |

High-impact write tools (posting, task updates, Sheets create/write, Drive share, GitHub/GitLab review and merge workflows, `ssh exec`) are gated by local approval prompts before they run; read tools run without a prompt.

> **Privacy boundary:** shared tokens are usable by every Claude Bar account configured on this Mac. If iCloud Sync is enabled, the same connector tokens are available to Macs that share your Apple ID and know the Claude Bar sync passphrase. Tool results still flow through your Claude account's chat history, which may be shared if you share that Claude login.

---

## How auto-swap works

1. **Polls usage** every N seconds with adaptive frequency — faster as you approach the threshold
2. Active 5h usage ≥ threshold → notification **"Auto-swap in 60s (X% used)"** — 60-second grace window; close `claude` now if you want it to finish cleanly first
3. After the grace, **swaps** to the inactive account with the lowest 5-hour usage (highest subscription tier preferred). The swap goes through even if a `claude` session is still live — Claude Bar does not kill the process, the next invocation simply picks up the new account
4. Notification **"Switched to [account]"** — confirmation after the swap completes
5. Triggers **IDE reload** (VSCode / Code Insiders / Cursor / Windsurf / Antigravity) and **CLI restart** (`claude-watch`) if those options are enabled in Settings

If all inactive accounts are also above the threshold → notification **"All accounts above threshold"**, retry in 10 minutes.

> Auto-swap is driven by the **5-hour** window exclusively. The 7-day window is displayed for reference but does not affect swap decisions.

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

To also remove all data (accounts, settings, claude-watch script):

```bash
rm -rf "$HOME/Library/Application Support/claude-bar"
defaults delete dev.ncthanhngo.claude-bar 2>/dev/null
# Remove shell alias if you added it
sed -i '' '/alias claude="claude-watch"/d' ~/.zshrc
```

---

## Build from source

Requirements: macOS 14+, Xcode 15+, Go 1.23+

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
3. For anything that touches credentials, syncing, or the MCP gateway, read [SECURITY.md](./SECURITY.md) first and call out the trust-boundary impact in your PR description.

---

## Security

Claude Bar is local-first and opt-in for any data that leaves your Mac. See [SECURITY.md](./SECURITY.md) for data flows, trust boundaries, and the threat model. Report vulnerabilities to nc.thanhngo@gmail.com with subject prefix `[security]`.

---

## License

[MIT](./LICENSE)
