# Usage

## First run

```bash
bash scripts/build-app.sh
open "dist/Claude Widget.app"
```

macOS blocks unsigned apps on first launch:
- System Settings → Privacy & Security → scroll to "Claude Widget was blocked" → **Open Anyway**.
- Or right-click the app → **Open** → confirm **Open** in the dialog.

After launch, the **gauge icon + `<percent>% · <hh>h<mm>m` label** appears in the menu bar.

## Reading the menu bar

Format: `<percent>% · <hh>h<mm>m`

Example: `47% · 2h13m` = used 47% of the 5h block limit, 2h13m until reset.

Color thresholds:
- `< 60%` → green
- `60–85%` → orange
- `≥ 85%` → red

## Menu bar interactions

| Action | Result |
|---|---|
| **Left-click** the icon | Toggle the main popover |
| **Right-click** (or Ctrl-click) | Open the quick-switch menu — pick an account directly without opening the popover |

The quick-switch menu lists all saved accounts with their last-known % (when polling is on), a checkmark next to the active one, plus shortcuts to **Show usage…** and **Quit**.

## Popover layout

1. **Web connection banner** — only visible if the widget is **not** connected to claude.ai. Shows "Connect" CTA. Once connected, it disappears (replaced by the per-row cloud badge).
2. **Hero card** — current 5h block: large %, reset countdown, weekly bar (if connected), tokens, block window. `LIVE` badge = data from claude.ai API; `ESTIMATED` = JSONL fallback.
3. **Accounts list** — saved profiles (see [Account management](#account-management)).
4. **Auto-switch card** — toggle + threshold slider for automatic rotation (see [Auto-switch](#auto-switch)).
5. **Pending switch banner** (orange, conditional) — appears when auto-switch wants to rotate but `claude` CLI is still running.

The header has a refresh button (force re-scan + web fetch) and a gear icon (open Settings).

## Account management

The widget stores accounts in `~/Library/Application Support/ClaudeWidget/accounts.json`. Each account holds an **OAuth blob** (Claude Code CLI tokens, used for switching the CLI) and optionally a **web session** (`sessionKey + orgId`, used to fetch realtime usage % from claude.ai).

### Add an account

Click **Add** in the popover → choose one of three methods:

#### 1. Open Claude login

> Use when you want to log into a **new** Claude account from scratch.

The widget opens Terminal and runs `claude logout && claude`. You complete the OAuth flow in your default browser (sign in with Google / Apple / Microsoft / email magic link / SSO — any provider Claude supports). When `claude` finishes writing tokens to the macOS Keychain, the widget's watcher detects the change and prompts you for a label.

If a different account is already logged in, the widget warns you first — you can **Save current first** (snapshot the existing login before logout) or **Continue — already saved** (proceed knowing the previous credentials are preserved elsewhere).

#### 2. Magic link

> Use for Claude **Teams workspaces** where an admin sent you a one-time `https://claude.ai/magic-link#…` URL and you don't have direct email/password access.

Paste the magic link → the widget loads it in a hidden WebView (which sets the `sessionKey` cookie), then spawns `claude` CLI, captures the OAuth URL from its stdout, and navigates the same WebView to it. Because the cookie is already set, Claude's auth backend skips the login UI and redirects straight to the CLI's localhost callback → `claude` receives the auth code and writes OAuth tokens to Keychain.

End result: the widget saves both the **OAuth blob** (for CLI switching) AND the **web session** (for realtime polling) in one shot.

#### 3. Snapshot current

> Use when you've **already** logged into `claude` CLI manually (in a Terminal session, outside the widget) and just want to register that existing login as a widget account.

This is the simplest path. The widget reads the current Keychain blob, lets you label it, and saves. No Terminal spawn, no browser, no OAuth flow — purely a snapshot of whatever's already in the Keychain.

After a snapshot, the widget also inherits the **global** claude.ai sessionKey (if you've previously clicked "Connect to claude.ai") into the new account row. If no global session exists, the row will show an orange ☁️ icon — use the row's ⋯ menu → **Connect web** to add one.

### Per-row actions

Each account row in the popover has a ⋯ menu:

| Menu item | What it does |
|---|---|
| **Switch** (button on row, not menu) | Make this account active. Updates the Keychain so the next `claude` invocation uses these tokens. Posts a notification. If `claude` is currently running, an alert explains the implication (running sessions keep their current token until quit/refresh). |
| **Connect web** / **Reconnect web** | Open a Claude login window. Sign in as **this account's identity**. The widget captures the resulting `sessionKey + orgId` and attaches it to this row only — does not switch the CLI. Required for multi-account polling. |
| **Disconnect web** | Clear this row's saved `sessionKey + orgId`. If the row is currently active, also clears the global web session (HeroCard goes back to JSONL-estimated). |
| **Remove** | Delete the account row from the widget. The original Claude Code login in Keychain is untouched. |

### Cloud badge meanings

The small cloud icon next to a row's status:

| Icon | Meaning |
|---|---|
| ☁️ **Blue (filled)** | Web session saved, polling enabled — this row gets fresh % every poll cycle |
| ☁️ **Grey (filled)** | Web session saved, polling disabled — enable in Settings to get fresh % |
| ☁️ **Orange (outline, clickable)** | No web session — usage % can't be polled. Click it to start the Connect web flow |

### Duplicate detection

When you click **Save** in any wizard, the widget compares the new credentials against existing rows by extracting a stable identifier (account UUID / email) from the OAuth blob. If a duplicate is detected:

> ⚠️ This account is already saved. These credentials match the row "**…**". Saving will create a second snapshot of the same identity.
> [Save anyway] [Cancel]

Cancel returns to the wizard; **Save anyway** bypasses the check (useful if you actually want two snapshots, e.g., for testing).

## Multi-account polling (Settings)

Open the gear icon → **Settings**:

### Track all accounts (realtime)

When **off** (default): only the active account's % is fetched (every 60s).

When **on**: the widget additionally polls every other saved account that has a web session, refreshing each row's `lastSessionPercent` on a configurable interval.

Each poll round:
1. Save the active account's cookie.
2. For each non-active account with `sessionKey`: swap the WebKit cookie, fetch `/api/organizations/<orgId>/usage`, store the result on disk.
3. Restore the active account's cookie at the end.

Round time ≈ 3-5s per account (Cloudflare + WebKit render is sequential, since one WebKit cookie store).

### Refresh interval

Pick a preset (**1m / 5m / 15m**) or enter a custom value in minutes. Shorter intervals refresh faster but burn battery and risk Anthropic rate-limits. Recommend 5m+ for 3+ accounts.

### Polling status

When polling is enabled, this card shows how many of your accounts are pollable. Accounts missing a web session are listed with a reminder to use the row's ⋯ menu → **Connect web**.

## Switch readiness

The third Settings card lets you **verify** each saved account can participate in auto-switch. Click **Verify all accounts** — the widget checks each one sequentially (~2-5s each) and reports a status:

| Status | Reason | How to fix |
|---|---|---|
| ✅ **Ready** | OAuth blob present + web session valid | Nothing to do |
| ❌ **Missing OAuth blob** | Account record corrupted | Remove the row → re-add via Add → Open Claude login or Magic link |
| ⚠️ **Missing web session** | No `sessionKey + orgId` saved | Popover → row ⋯ menu → **Connect web** → sign in as this account |
| ⚠️ **Web session expired** | Cookie was revoked or aged out | Popover → row ⋯ menu → **Reconnect web** |

A summary badge ("3/3 ready") tells you at a glance whether auto-switch can rotate freely.

## Auto-switch

In the popover, the **Auto-switch accounts** card has a toggle + threshold slider.

- **Off**: widget never switches CLI Keychain automatically.
- **On**: when the active account's session % crosses the threshold (50–99%, default 95%), the widget picks the **non-active account with the lowest known usage %** and switches the CLI to it.

### Candidate selection

If any non-active account has been observed (has `lastSessionPercent`), the widget prefers the lowest-usage one. If none have been observed (polling never ran), it falls back to the first non-active account by creation order — deterministic but blind.

→ For best results: enable **Track all accounts** so candidates are picked from fresh data.

### Pending switch (CLI safety)

Before switching, the widget runs `pgrep` to detect running `claude` CLI processes:

- **No `claude` running** → switch immediately + post notification.
- **`claude` running** → defer: an orange **Pending switch** banner appears in the popover, plus a notification. The widget polls every 15s; the moment all `claude` PIDs exit, the switch fires and a second notification confirms.

You can cancel a pending switch via the banner's **Cancel** button (the threshold check resumes next cycle).

### Manual switch

Both methods below use the same confirmation dialog (with CLI-running detection) and post a notification after success:

- **Popover**: click the **Switch** button on an inactive row.
- **Menubar**: right-click the menubar icon → pick the account.

The alert wording adapts:
- If `claude` is **not** running: "Your Keychain will be updated. Run `claude` to start using this account."
- If `claude` **is** running: shows the session count and explains running sessions keep their current token until quit or refresh (~1h).

## File locations

| Purpose | Path |
|---|---|
| Account list (OAuth blobs + per-row web sessions) | `~/Library/Application Support/ClaudeWidget/accounts.json` |
| Widget config (intervals, threshold, etc.) | `~/Library/Application Support/ClaudeWidget/config.json` |
| Global web session (active account's cookie) | macOS Keychain via `SecretStore.widget` |
| Claude Code CLI tokens | macOS Keychain entry `Claude Code-credentials` |
| Local usage transcripts (read-only) | `~/.claude/projects/<slug>/*.jsonl` |

## Refresh schedule

| Timer | Interval | What it does |
|---|---|---|
| UI tick | 5s | Recompute snapshot from cached data; update menubar label |
| JSONL rescan | 15s | Re-read `~/.claude/projects/` for local token totals |
| Active web fetch | 60s | Call `claude.ai/api/.../usage` for the active account |
| Multi-account poll | configurable (60s+) | Loop over inactive accounts; only when "Track all accounts" is on |
| Pending switch poll | 15s | Active only when a pending switch is waiting on `claude` to quit |

## Troubleshooting

**Label shows `··`**
→ First scan in progress. Wait 1-2 seconds.

**Label shows `idle`**
→ No assistant messages in the last 5h or `~/.claude/projects/` is empty. Send a message in Claude Code to start a new block.

**HeroCard shows `ESTIMATED`, not `LIVE`**
→ No web session saved. Click the orange ☁️ icon on the active account's row to connect, or use the Settings → Switch readiness card to verify.

**Magic link wizard times out at "Starting claude CLI…"**
→ The CLI didn't print the OAuth URL within 45s — likely a TTY issue (it needs a real terminal). Fallback: open Terminal, run `claude logout && claude`, complete the login manually, then use **Snapshot current** to save the result.

**Auto-switch banner stuck on "Waiting for N `claude` sessions"**
→ One or more `claude` processes are still running. Quit them (close Terminal tabs / VSCode windows running Claude Code). The widget polls every 15s.

**Switch happened but `claude` still uses the old account**
→ The running `claude` process cached its token in RAM. Quit and rerun `claude` to pick up the new identity.

**The menubar app vanished**
→ Menu bar might be full. Use `Cmd+drag` on the icon to reorder, or quit + relaunch via Activity Monitor (`killall ClaudeWidget` → `open "/Applications/Claude Widget.app"`).

**Need to reset everything**
→ Quit the app, then `rm -rf ~/Library/Application\ Support/ClaudeWidget/` and reopen. Keychain entries are not touched.
