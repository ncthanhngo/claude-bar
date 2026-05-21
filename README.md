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
- **Credential health** — inactive accounts that can no longer refresh are marked before a broken switch
- **Usage display** — 5-hour and 7-day quota bars with % and time-until-reset for each account
- **Auto-swap** — automatically switches to a lower-usage account when the active one hits your threshold; waits for `claude` to exit first, then notifies you
- **IDE reload** — after a swap, reloads VSCode / Code Insiders / Cursor / Windsurf / Antigravity windows so the extension picks up new credentials (requires Accessibility permission). Reload shortcut is user-configurable (default `⌃⌘R`) and auto-installed into each editor's `keybindings.json`
- **CLI auto-restart** — sends SIGINT to running `claude` sessions; use with the bundled `claude-watch` wrapper to auto-restart in your terminal
- **Session guard** — warns you if Claude is running before a manual switch; option to force-switch anyway
- **Web fallback** — embedded WKWebView for fetching usage data when the Anthropic API is rate-limited
- **Themes** — Light, Dark, and Rainbow
- **Icon color** — 11 preset tint colors for the menu bar icon (Settings → General)

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

Enable **Auto-kill CLI sessions** in Settings → General. Claude Bar automatically installs `claude-watch` and adds the shell alias on first launch — no manual steps needed. When a swap happens, your terminal session (including GoLand's integrated terminal) restarts automatically with the new account credentials.

### IDE reload — VSCode / Code Insiders / Cursor / Windsurf / Antigravity

Enable **Auto-reload IDE after swap** in Settings → General, then click **Grant Access** when the Accessibility prompt appears. Claude Bar will reload supported IDE windows after each swap.

**Reload shortcut.** Default is `⌃⌘R` (Cmd+Ctrl+R) — picked to avoid clashes with VSCode's `⌘R` (Recent Files) and Cursor's `⇧⌘R` (Rerun). Change it in **Settings → General → Reload shortcut** via the key recorder; the new chord is re-applied to every detected editor instantly.

**How injection works.** With *Install shortcut into IDE keybindings.json* enabled (default), Claude Bar adds one entry to each detected editor's `keybindings.json` tagged with `"when": "!falseClaudeBarManaged"`. Toggle off to revert to the legacy `⌘⇧P → Developer: Reload Window` command-palette flow. Zed uses its own keymap and is unaffected. Managed-state lives at `~/Library/Application Support/claude-bar/managed-shortcuts.json` and is cleaned up automatically when the shortcut changes or injection is disabled.

### Local MCP connectors (optional)

Claude Bar can keep one shared set of Slack, ClickUp, and Google Workspace tokens for every account on this Mac, plus optional per-account overrides. Claude Code reaches them through a local stdio gateway. Tokens stay in the macOS Keychain locally; if iCloud Sync is enabled, they are copied only into the passphrase-encrypted Claude Bar iCloud bundle so another Mac signed into the same Apple ID can restore them into its own Keychain. Switching accounts in the menu bar swaps to that account's override when present; otherwise it uses the shared connector — no Claude Code restart required.

1. Open **Settings → Local MCP**.
2. Click **Install** to wire `claude-bar-mcp` into `~/.claude.json`.
3. In **Shared for all accounts**, click **Connect** next to each service you want to use across all Claude Bar accounts. Use per-account rows only when an account should override the shared connector.
   - Slack/ClickUp: paste a user token (Slack `xoxp-…` or `xoxe-…` / ClickUp `pk_…`). Slack bot tokens (`xoxb-…`) are not supported because Slack search requires a user token. The token is piped to `csw` over stdin and never appears in argv or shell history.
   - Google Workspace: enable Drive, Calendar, and Gmail APIs in Google Cloud, paste your OAuth Desktop client ID/secret or import the downloaded JSON file, then click **Open browser to connect**. PKCE (S256) is still used.
4. Restart Claude Code once so it picks up the new MCP server. After that, switching Claude Bar accounts is hot — Claude Code keeps running.

Tools currently exposed (read-only): `cb_slack_list_channels`, `cb_slack_search_messages`, `cb_slack_get_thread`, `cb_clickup_list_workspaces`, `cb_clickup_list_spaces`, `cb_clickup_list_folders`, `cb_clickup_list_lists`, `cb_clickup_list_tasks`, `cb_clickup_get_task`, `cb_gdrive_search_files`, `cb_gdrive_get_file_metadata`, `cb_gdrive_get_doc_text`, `cb_gcal_list_events`, `cb_gcal_get_event`, `cb_gmail_search_messages`, `cb_gmail_get_message`.

> **Privacy boundary:** shared tokens are usable by every Claude Bar account configured on this Mac. If iCloud Sync is enabled, the same connector tokens are available to Macs that share your Apple ID and know the Claude Bar sync passphrase. Tool results still flow through your Claude account's chat history, which may be shared if you share that Claude login.

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
6. Triggers **IDE reload** (VSCode / Code Insiders / Cursor / Windsurf / Antigravity) and **CLI restart** (`claude-watch`) if those options are enabled in Settings

If all inactive accounts are also above the threshold → notification **"All accounts above threshold"**, retry in 10 minutes.

> Auto-swap is driven by the **5-hour** window exclusively. The 7-day window is displayed for reference but does not affect swap decisions.

---

## License

MIT
