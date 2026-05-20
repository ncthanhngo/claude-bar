# Claude Bar

A macOS menu-bar app for managing multiple [Claude Code](https://claude.ai/code) accounts. Switch between accounts instantly, auto-swap when quota runs out, and keep your IDE in sync.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![License MIT](https://img.shields.io/badge/license-MIT-green)

---

## Install via Homebrew

```bash
brew tap ncthanhngo/tap
brew install --cask claude-bar
```

---

## Features

- **Multi-account management** — add, rename, and switch Claude Code accounts from the menu bar
- **Usage display** — 5-hour and 7-day quota bars with % and time-until-reset for each account
- **Auto-swap** — automatically switches to a lower-usage account when the active one hits your threshold; waits for `claude` to exit first, then notifies you
- **IDE reload** — after a swap, reloads VSCode / Cursor / Windsurf windows so the extension picks up new credentials (requires Accessibility permission)
- **CLI auto-restart** — sends SIGINT to running `claude` sessions; use with the bundled `claude-watch` wrapper to auto-restart in your terminal
- **Session guard** — warns you if Claude is running before a manual switch; option to force-switch anyway
- **Web fallback** — embedded WKWebView for fetching usage data when the Anthropic API is rate-limited
- **Themes** — Light, Dark, and Rainbow

---

## Manual install

1. Download `ClaudeBar.zip` from [Releases](https://github.com/ncthanhngo/claude-bar/releases/latest)
2. Unzip and drag `ClaudeBar.app` to `/Applications`
3. Launch — the icon appears in your menu bar

---

## Setup

### Add accounts

Open **Settings → Accounts → Add account**. Each account needs a separate Claude Code login (`claude /login`).

### Auto-restart terminal sessions

Enable **Auto-kill CLI sessions** in Settings → General, then run once in your terminal:

```bash
# Install claude-watch (written by Claude Bar on first launch)
chmod +x "$HOME/Library/Application Support/claude-bar/claude-watch.sh" \
  && ln -sf "$HOME/Library/Application Support/claude-bar/claude-watch.sh" \
     /opt/homebrew/bin/claude-watch

# Make every `claude` call auto-restart after a swap
echo 'alias claude="claude-watch"' >> ~/.zshrc && source ~/.zshrc
```

After this, when a swap happens your terminal session (including GoLand's integrated terminal) restarts automatically with the new account credentials.

### IDE reload — VSCode / Cursor / Windsurf

Enable **Auto-reload IDE after swap** in Settings → General, then click **Grant Access** when the Accessibility prompt appears. Claude Bar will send `⌘⇧P → Developer: Reload Window` after each swap.

### Local MCP connectors (optional)

Each Claude Bar account can own a private set of Slack, ClickUp, and Google Drive tokens that Claude Code reaches through a local stdio gateway. Tokens stay on this Mac in the macOS Keychain and never touch the repo, `~/.claude.json`, logs, or the iCloud sync bundle. Switching accounts in the menu bar swaps which tokens the next tool call uses — no Claude Code restart required.

1. Open **Settings → Local MCP**.
2. Click **Install** to wire `claude-bar-mcp` into `~/.claude.json`.
3. For each account, click **Connect** next to the service you want.
   - Slack/ClickUp: paste a user token (Slack `xoxp-…` / ClickUp `pk_…`). The token is piped to `csw` over stdin and never appears in argv or shell history.
   - Google Drive: paste your Google OAuth Desktop client ID, then click **Open browser to connect**. PKCE (S256) is used, so no client secret is needed.
4. Restart Claude Code once so it picks up the new MCP server. After that, switching Claude Bar accounts is hot — Claude Code keeps running.

Tools currently exposed (read-only): `cb_slack_list_channels`, `cb_slack_search_messages`, `cb_slack_get_thread`, `cb_clickup_list_workspaces`, `cb_clickup_list_tasks`, `cb_clickup_get_task`, `cb_gdrive_search_files`, `cb_gdrive_get_file_metadata`, `cb_gdrive_get_doc_text`.

> **Privacy boundary:** local tokens stay on this Mac, but tool results still flow through your Claude account's chat history, which may be shared if you share that Claude login. Anyone else logged into the same Claude account on a *different* Mac cannot use these connectors unless they install Claude Bar there too.

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

---

## How auto-swap works

1. **Polls usage** every N seconds with adaptive frequency — faster as you approach the threshold
2. Active 5h usage ≥ threshold → notification **"Auto-swap pending (X% used)"** — you are warned before anything happens
3. **Waits** until no `claude` sessions are busy (`safeToSwap = true`) — Claude Bar never interrupts a running session
4. **Swaps** to the inactive account with the lowest 5-hour usage
5. Notification **"Switched to [account]"** — confirmation after the swap completes
6. Triggers **IDE reload** (VSCode/Cursor/Windsurf) and **CLI restart** (`claude-watch`) if those options are enabled in Settings

If all inactive accounts are also above the threshold → notification **"All accounts above threshold"**, retry in 10 minutes.

> Auto-swap is driven by the **5-hour** window exclusively. The 7-day window is displayed for reference but does not affect swap decisions.

---

## License

MIT
