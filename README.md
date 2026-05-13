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
- **Multi-account** — snapshot every `claude` login, switch with one click
- **Auto-switch** when active account hits a threshold (default 95%) → rotates to the account with the lowest known usage, sends a macOS notification
- **Web sign-in** via WKWebView (no DevTools cookie copying)
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

Or via UI: *System Settings → Privacy & Security → Open Anyway*. One time only.

---

## Setup, in three clicks

1. **Connect** banner → **Sign in with Claude** → log in inside the embedded Anthropic window. The widget grabs your `sessionKey` cookie and starts polling real usage numbers.
2. Sign into Claude Code with the `claude` CLI, then **+ Add** in the widget → label the account. Repeat for each account you want to rotate between.
3. Flip **Auto-switch accounts** on → drag the slider to your threshold.

Done. The widget pesters you with notifications when it rotates; otherwise it shuts up.

---

## How it works (5-minute version)

- **Realtime usage** = polled from `claude.ai/api/organizations/<orgId>/usage`, the same endpoint claude.ai's billing page calls. Goes through a hidden WKWebView because Cloudflare refuses to talk to raw `URLSession`.
- **Multi-account** = read/write the macOS Keychain item Claude Code stores its OAuth in (`Claude Code-credentials`). Same pattern [`claude-swap`](https://github.com/realiti4/claude-swap) uses on the CLI.
- **State** lives in `~/Library/Application Support/ClaudeWidget/` (`config.json`, `accounts.json`, `widget-secrets.json`, all mode `0600`).
- **Fallback**: not connected? It parses `~/.claude/projects/**/*.jsonl` directly and computes 5h blocks like [`ccusage`](https://github.com/ryoppippi/ccusage). Less accurate (Anthropic doesn't publish the exact 5h token cap) but at least it works offline.

---

## Honest limitations

- **Restart `claude` after switching** — the CLI reads its Keychain once at startup, doesn't hot-reload. There's no way around this without a Claude Code patch.
- **Per-account usage tracking** uses one shared web session, so the % shown is for whichever account you signed into the widget — not necessarily the active CLI account. Disconnect + reconnect after switching if you need exact numbers.
- **Unsigned binary** = first-launch Gatekeeper friction. Apple Developer ID costs $99/year and I would like to keep eating.
- **Plan limits are guesses** in JSONL-fallback mode. The web mode doesn't care.

---

## Architecture

Six layers, dependency flows one way (`UI → State → Services → Persistence → Domain`). Full rules in [`CLAUDE.md`](CLAUDE.md). The short version:

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

---

## Credits

Standing on three shoulders:
- [SlavomirDurej/claude-usage-widget](https://github.com/SlavomirDurej/claude-usage-widget) — found `/api/organizations/<id>/usage`
- [realiti4/claude-swap](https://github.com/realiti4/claude-swap) — the Keychain swap pattern
- [ryoppippi/ccusage](https://github.com/ryoppippi/ccusage) — JSONL block algorithm

Unofficial. Not affiliated with Anthropic. They make Claude; this just stares at how much of it I've used.

## License

MIT.
