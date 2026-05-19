# claude-bar

> A native macOS menu bar widget for Claude usage.
>
> Because alt-tabbing to `claude.ai/settings/billing` every 10 minutes to check whether you've burned through your 5-hour window is no way to spend a Tuesday afternoon.

```
 ▎23% · 1h47m    ← always there, top-right of your screen
```

Click it for the full popover: session %, weekly bar, accounts, auto-switch.

---

## What it does

- **Realtime session %** — same numbers Claude Code's `/usage` shows, polled every 60s
- **Reset countdown** in the menu bar, ticking down every 5s
- **Right-click → quick-switch** menu — pick an active account without opening the popover
- **Multi-account, three ways to add**:
  - **Open Claude login** — widget drives `claude logout && claude` for you, snapshots the result
  - **Magic link** — paste a Teams workspace link, widget completes the OAuth flow in a hidden WebView (no email/password access needed)
  - **Snapshot current** — register the existing `claude` CLI login as a widget account
- **Per-account realtime polling** — opt-in: fetch `% used` for every saved account, not just the active one. Configurable interval (1–N minutes)
- **Auto-switch with CLI safety** — when active hits the threshold, picks the lowest-usage account, but **defers the switch if `claude` is still running** (avoids cutting off your work mid-turn). Shows a pending banner + notification; switch fires once all `claude` processes quit
- **Switch readiness verifier** — Settings → check each account against the auto-switch chain (OAuth blob, web session validity); reports per-account fix instructions
- **Duplicate detection** — warns before saving a second snapshot of the same identity
- **Idle**: ~0 % CPU, ~30 MB RAM
- No telemetry. No daemon. No API key required.

---

## Install

### Homebrew Cask

```bash
brew tap ncthanhngo/claude-bar https://github.com/ncthanhngo/claude-bar
brew install --cask ncthanhngo/claude-bar/claude-bar
```

Upgrade later with `brew update && brew upgrade --cask claude-bar`.

#### Upgrade fails with `Cask 'claude-bar' is unreadable` / `syntax errors` / `could not apply ... initial public release`

The local tap clone is stuck mid-rebase with conflict markers in `Casks/claude-bar.rb`. Repo on GitHub is fine — only the machine's tap copy is broken. Reset by untapping and retapping:

```bash
brew untap ncthanhngo/claude-bar
brew tap ncthanhngo/claude-bar https://github.com/ncthanhngo/claude-bar
brew upgrade --cask claude-bar
```

### DMG (the boring way)

Download from [Releases](https://github.com/ncthanhngo/claude-bar/releases) → drag into Applications.

### From source (for people who like Swift compilers)

```bash
git clone git@github.com:ncthanhngo/claude-bar.git
cd claude-bar
bash scripts/install-to-applications.sh
```

Needs Xcode CLT (`xcode-select --install`). Built with SwiftPM, no Xcode project.

**First launch (any method)** — macOS will refuse to open an unsigned app. Either:

```bash
sudo xattr -dr com.apple.quarantine "/Applications/Claude Widget.app"
open "/Applications/Claude Widget.app"
```

Or via UI: _System Settings → Privacy & Security → Open Anyway_. One time only.

---

## Setup

1. **Connect** banner → **Connect** → sign in inside the embedded Anthropic window. The widget grabs your `sessionKey` cookie and HeroCard goes `LIVE`.
2. **+ Add** in the widget. Pick the path that fits:
   - Already logged into `claude` CLI? → **Snapshot current** (one click)
   - Want to log into a fresh account? → **Open Claude login**
   - Got a Teams magic link from your admin? → **Magic link** (paste the URL)

   Repeat for each account you want to rotate.
3. Gear icon → **Settings**:
   - Toggle **Track all accounts** on, pick an interval (1m / 5m / 15m / custom). This is what makes inactive rows show fresh % so auto-switch picks smart candidates.
   - Click **Verify all accounts** in the Switch readiness card — anything not ✅ Ready gets a one-line fix.
4. Back in the popover, flip **Auto-switch accounts** on → drag the slider to your threshold.

Done. Notifications fire on every switch (manual + auto); the pending banner appears if a switch is held back by running `claude` sessions.

See [`docs/usage.md`](docs/usage.md) for full reference (what each option means, file locations, cloud-badge meanings, troubleshooting).

---

## How it works (5-minute version)

- **Realtime usage** = polled from `claude.ai/api/organizations/<orgId>/usage`, the same endpoint claude.ai's billing page calls. Goes through a hidden WKWebView because Cloudflare refuses to talk to raw `URLSession`.
- **Multi-account** = read/write the macOS Keychain item Claude Code stores its OAuth in (`Claude Code-credentials`). Same pattern [`claude-swap`](https://github.com/realiti4/claude-swap) uses on the CLI.
- **Per-account polling** = swap the WebKit cookie store between each account's saved `sessionKey`, fetch sequentially, restore the active account's cookie at the end. ~3-5s per account; configurable cadence.
- **Magic-link login** = load the link in a hidden WebView (sets cookie), spawn `claude` CLI, scrape the OAuth URL from stdout, navigate the same WebView there (cookie auto-completes the PKCE flow → CLI receives auth code → tokens land in Keychain → watcher detects).
- **CLI safety on switch** = `pgrep -lf claude` (filtered by argv[0] basename = `claude` exactly, so Claude.app helpers and ShipIt don't false-positive) before every auto-switch. If anything's running, pending state until idle.
- **Duplicate detection** = recursive JSON search of the OAuth blob for stable identifiers (uuid, email). Token bytes rotate; identity doesn't.
- **State** lives in `~/Library/Application Support/ClaudeWidget/` (`config.json`, `accounts.json`, `widget-secrets.json`, all mode `0600`).
- **Fallback**: not connected? It parses `~/.claude/projects/**/*.jsonl` directly and computes 5h blocks like [`ccusage`](https://github.com/ryoppippi/ccusage). Less accurate (Anthropic doesn't publish the exact 5h token cap) but at least it works offline.

---

## Honest limitations

- **Restart `claude` after switching** — the CLI reads its Keychain once at startup, doesn't hot-reload. Auto-switch defers until your sessions quit (so you don't lose context mid-turn), but you still need to run `claude` again to start using the new account.
- **Magic-link login depends on `claude` printing the OAuth URL to stdout.** Tested with the current version; if a future CLI release writes only to `/dev/tty`, the wizard will time out after 45s and tell you to fall back to **Snapshot current**.
- **Per-account polling shares one WebKit cookie store** — fetches are sequential (~3-5s × N accounts per round). Plenty fast for 3-5 accounts at 1m+ intervals; not designed for 20-account fleets.
- **Anthropic rate-limits aren't documented**. Recommend ≥1m polling for 3+ accounts. If you start seeing fetch errors, raise the interval.
- **`pgrep` parser splits on whitespace** — if your home directory has spaces (`/Users/Joe Smith/`), CLI detection may miss processes. Rename or accept the gap (uncommon edge case).
- **Unsigned binary** = first-launch Gatekeeper friction. Apple Developer ID costs $99/year and I would like to keep eating.
- **Plan limits are guesses** in JSONL-fallback mode. The web mode doesn't care.

---

## Architecture

Six layers, dependency flows one way (`UI → State → Services → Persistence → Domain`). The short version:

```
Sources/ClaudeWidget/
├── App/             entry + NSStatusItem wiring
├── Domain/          pure value types (Account, SessionBlock, UsageSnapshot, …)
├── Persistence/     file/keychain-backed stores
├── Services/        WebUsageService, AccountStore, AutoSwitcher, JsonlUsageService, …
├── State/           UsageStore (the only @MainActor ObservableObject the UI binds to)
└── UI/              PopoverView + Sections/ + Sheets/
```

---

## Build & release

```bash
bash scripts/install-to-applications.sh        # build .app + relaunch
bash scripts/package-dmg.sh 0.7.3              # → ClaudeWidget-0.7.3.dmg
bash scripts/release.sh 0.7.3                  # bump + DMG + cask sha256 + gh release
```

Releasing pushes a new GitHub release and updates `Casks/claude-bar.rb`.

## Tests

```bash
swift test
```

49 unit tests covering pure logic: OAuth blob inspection, auto-switch candidate selection, magic-link URL parsing, pgrep output parsing, usage snapshot composition, pending-switch state. Run in ~10ms, no GUI / network / Keychain access required. UI flows + subprocess paths are manual — see `docs/usage.md` § Troubleshooting for likely-to-fail scenarios.

---

## Credits

Standing on three shoulders:

- [SlavomirDurej/claude-usage-widget](https://github.com/SlavomirDurej/claude-usage-widget) — found `/api/organizations/<id>/usage`
- [realiti4/claude-swap](https://github.com/realiti4/claude-swap) — the Keychain swap pattern
- [ryoppippi/ccusage](https://github.com/ryoppippi/ccusage) — JSONL block algorithm

Unofficial. Not affiliated with Anthropic. They make Claude; this just stares at how much of it I've used.

## License

Thanh Ngô
