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
4. Read the target account's backup creds.
5. Write target creds into the live Keychain entry (`Claude Code-credentials`).
6. Patch `~/.claude.json`: only `oauthAccount` is replaced — every other field is left untouched.
7. Update registry's `activeAccountNumber`. Save (atomic write, 0600).
8. On any failure, roll back: restore prior creds + config.

## Usage fetch

- Endpoint: `GET https://api.anthropic.com/api/oauth/usage`
  - `Authorization: Bearer <accessToken>`
  - `anthropic-beta: oauth-2025-04-20`
- Response: `{five_hour: {utilization, resets_at}, seven_day: {utilization, resets_at}}`
- Inactive accounts: if the access token is within 5 min of expiry, the widget
  calls `POST https://platform.claude.com/v1/oauth/token` with `refresh_token`
  and persists the refreshed creds back to the backup keychain entry.
- Active account: **never** refreshed by the widget — `claude` itself owns
  refresh for the live token, and a race could clobber the user's session.

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
| `~/.claude.json` | Claude Code (we patch `oauthAccount` + `mcpServers["claude-bar-mcp"]`) | preserved as-is |
| Keychain `claude-bar-mcp:*` | csw via `security` | per-user keychain |

## Local MCP gateway

Optional feature. When the user installs the gateway, Claude Code calls
`csw mcp serve` (the same packaged `csw` binary) over stdio. The gateway
exposes nine read-only tools (`cb_slack_*`, `cb_clickup_*`, `cb_gdrive_*`)
and resolves the **active Claude Bar account per tool call** — switching
accounts in the menu bar swaps which token the next call uses, with no
Claude Code restart required.

```
Claude Code
  └─ stdio ─▶  csw mcp serve
                └─ Resolver  ─▶  registry.json  (active account)
                              ─▶  Keychain "claude-bar-mcp:<n>:<svc>"
                              ─▶  Slack / ClickUp / Google APIs
```

Privacy boundary, scopes, redaction rules, and disconnect/revoke contract
live in `docs/local-mcp-threat-model.md`. The iCloud sync bundle
**intentionally excludes** `mcpConnectors` metadata; a structural test in
`backend/internal/adapter/cloudsync/mcp_exclusion_test.go` keeps it that way.
