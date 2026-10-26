# Architecture

Clean / hexagonal layout: domain at the centre, use-cases above, adapters at the edges.
Swift widget is a thin client that calls the Go backend via subprocess + JSON.

## Layered view

```
┌────────────────────────────────────────────────────────────────┐
│  widget (SwiftUI menu-bar app)                                 │
│  - View layer (MenuBarLabel, MenuContent, AddAccount, ...)     │
│  - State (AppStore, AppSettings, AutoSwapStateMachine,         │
│           LoginCoordinator)                                    │
│  - Backend bridge (CswClient → spawn csw + JSON decode)        │
└─────────────────────┬──────────────────────────────────────────┘
                      │ stdin/stdout, JSON
                      ▼
┌────────────────────────────────────────────────────────────────┐
│  csw (Go CLI)                                                  │
│  - cmd/csw/*                                                   │
└─────────────────────┬──────────────────────────────────────────┘
                      │
┌─────────────────────▼──────────────────────────────────────────┐
│  use-case layer (internal/usecase)                             │
│  AddAccount, SwitchAccount, ListAccounts, RenameAccount,       │
│  RemoveAccount, SessionsReport                                 │
└─────────────────────┬──────────────────────────────────────────┘
                      │ depends on ports only
┌─────────────────────▼──────────────────────────────────────────┐
│  port (internal/port)                                          │
│  LiveCredentialStore, BackupCredentialStore, ClaudeConfigStore,│
│  RegistryStore, UsageFetcher, TokenRefresher,                  │
│  SessionInspector, FileLock                                    │
└─────────────────────┬──────────────────────────────────────────┘
                      │ implemented by adapters
┌─────────────────────▼──────────────────────────────────────────┐
│  adapter (internal/adapter)                                    │
│  keychain/ (security CLI), claudeconfig/ (~/.claude.json),     │
│  registry/ (JSON file), sessions/ (~/.claude/sessions/),       │
│  oauth/ (HTTPS to Anthropic), lock/ (flock)                    │
└─────────────────────┬──────────────────────────────────────────┘
                      │
┌─────────────────────▼──────────────────────────────────────────┐
│  domain (internal/domain) — pure entities, no I/O              │
│  Account, Registry, CredentialBlob, OAuthPayload,              │
│  ClaudeConfig, Usage, Window, ClaudeSession, SessionReport     │
└────────────────────────────────────────────────────────────────┘
```

## Swap transaction (SwitchAccount)

1. Acquire flock on `~/Library/Application Support/claude-swap-widget/swap.lock`.
2. Read current live Keychain blob + `~/.claude.json`.
3. Persist them under the current active account's backup slot
   (Keychain service = `csw-backup:<num>:<email>`).
4. Refresh the target account's backup creds; fail with a re-login error if
   that backup can no longer refresh.
5. Wait (≤10s, non-acquiring) while Claude Code holds `~/.claude/.oauth_refresh.lock`,
   then write target creds into the live Keychain entry (`Claude Code-credentials`).
6. Patch `~/.claude.json`: only `oauthAccount` is replaced — every other field is left untouched.
7. Update registry's `activeAccountNumber`. Save (atomic write, 0600).
8. On any failure, roll back: restore prior creds + config.

Running `claude` processes are never signalled. Claude Code re-reads the live
Keychain item before each token check (30s read cache; also on a 401), so live
sessions use the new account from their next request — verified in Claude Code
2.1.310's `checkAndRefreshOAuthTokenIfNeeded`.

## Usage fetch

- Accounts may link isolated persistent WKWebView profiles. The widget tries
  each linked account's `claude.ai/settings/usage` web profile first.
- Web usage profiles and their cookies stay on this Mac (WebKit persists them);
  nothing is synced between Macs.
- Accounts without web usage, expired web sessions, or parse failures fall back
  to terminal/backend `GET https://api.anthropic.com/api/oauth/usage`.
  - `Authorization: Bearer <accessToken>`
  - `anthropic-beta: oauth-2025-04-20`
- Response: `{five_hour: {utilization, resets_at}, seven_day: {utilization, resets_at}}`
- The active account's usage uses the live access token (kept fresh by Claude
  Code); inactive accounts use their backup credentials.
- Active account live credentials are **never** refreshed by the widget —
  `claude` itself owns refresh for the live token.

## Keeping logins alive

Refresh tokens are single-use: each refresh revokes the previous token, so any
stale copy that gets spent or written back costs a login.

- **Refresh only when needed.** A backup is refreshed when its access token is
  expired (usage poll, verify) or has under 10 min left (swap); the
  Diagnostics "Force refresh" button is the only unconditional rotation. There
  is no background rotation and no cross-Mac sync.
- **One refresher at a time.** Every backup refresh — and a swap's read of
  its target — holds `~/Library/Application Support/claude-swap-widget/refresh.lock`
  (each `csw` command is its own process) and reads the backup straight from
  the Keychain, bypassing the per-process cache; if another process already
  rotated it, that result is used instead of spending the token again.
- **Never spend the live token.** A backup whose refresh token equals the live
  one belongs to the running Claude Code session and is not refreshed.
- **Backup follows live.** Each poll copies the live credential into the
  active account's backup when live is newer (later `expiresAt`), holding
  `swap.lock`, and only while `~/.claude.json` — re-read under the lock and
  again after reading live — attributes the login to that account.
- **Switching to the already-active account** keeps the live credential when
  `~/.claude.json` proves it is that account and it is not older than the
  backup; otherwise it installs the backup.
- Refresh and heal outcomes are logged to `~/Library/Logs/ClaudeBar/csw.log`.

## Process detection

- Source of truth: `~/.claude/sessions/{pid}.json` (Claude Code writes these itself).
- Each file: `{pid, sessionId, cwd, startedAt, kind, entrypoint, status}`.
- `status ∈ {busy, idle, waiting}`. Busy or waiting → not safe to swap.
- Liveness: `kill(pid, 0)`. EPERM = alive but not ours, ESRCH = dead.

## Auto-swap state machine

```
                ┌────────┐
                │  IDLE  │◄─────────────────┐
                └───┬────┘                  │
       active% ≥ threshold                  │ active% < threshold
                    │                       │ (already swapped)
                    ▼                       │
            ┌──────────────┐                │
            │ PENDING_SWAP │────────────────┤
            └───────┬──────┘                │
        sessions safeToSwap = true          │
                    │                       │
                    ▼                       │
              csw switch N                  │
                    │                       │
                    ▼                       │
              ┌──────────┐                  │
              │ COOLDOWN │──────────────────┘
              └──────────┘ (5 min)
```

State machine never kills processes; it only waits. `cooldown` prevents
flapping right after a swap while the new account's first request is in flight.

## File ownership

| File | Owner | Mode |
|---|---|---|
| `dist/ClaudeSwapWidget.app/Contents/MacOS/ClaudeSwapWidget` | Swift `swift build -c release` | Built by `make widget` |
| `dist/ClaudeSwapWidget.app/Contents/Resources/csw` | Go binary | Built by `make backend` |
| `~/Library/Application Support/claude-swap-widget/registry.json` | csw at runtime | 0600 |
| `~/Library/Application Support/claude-swap-widget/swap.lock` | csw flock | 0600 |
| Keychain `csw-backup:*` | csw via `security` | per-user keychain |
| Keychain `Claude Code-credentials` | Claude Code (we read/write same entry) | per-user keychain |
| `~/.claude.json` | Claude Code (we patch `oauthAccount`) | preserved as-is |
| Keychain `claude-bar-mcp:*` | Legacy connector tokens from the removed Local MCP feature; unread | per-user keychain |
