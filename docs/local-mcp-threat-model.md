# Local MCP Connectors — Threat Model & Privacy Contract

Status: Draft — phase 01 of `plans/20260520-2258-local-mcp-private-connectors`.

This is the **privacy contract** that every later phase MUST honor. If an
implementation choice conflicts with this document, the implementation is
wrong, not the document.

## 1. What this feature is

Local-only MCP gateway hosted by Claude Bar. Claude Code talks to the gateway
over stdio. The gateway resolves the **currently active Claude Bar account**
and loads that account's Slack / ClickUp / Google Drive credentials from the
macOS Keychain. Tokens never leave the Mac.

## 2. What this feature is NOT

- **Not** a way to make a shared Claude.ai login private. Chat transcripts,
  prompts, and tool-result text still flow through whatever Claude account the
  user is signed into. Anyone else sharing that Claude login can read tool
  results in chat history.
- **Not** a sandbox. Any code with access to the macOS user session can read
  the same Keychain items the gateway reads.
- **Not** a Claude Desktop integration in MVP. Claude Desktop is explicitly
  deferred.

## 3. Privacy boundary

```
┌──────────────────────────────────────────────────────────────────┐
│  Same Claude.ai login on a DIFFERENT Mac                         │
│  → has no local gateway binary                                   │
│  → has no local Keychain entries                                 │
│  → cannot invoke cb_slack_* / cb_clickup_* / cb_gdrive_* tools   │
│  → Claude Code on that Mac sees the tools as unavailable         │
└──────────────────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────────────────┐
│  Same Claude.ai login on THIS Mac, same macOS user               │
│  → can invoke local MCP tools                                    │
│  → protection level = macOS user-session security only           │
└──────────────────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────────────────┐
│  This Mac, DIFFERENT macOS user                                  │
│  → separate Keychain, separate registry                          │
│  → cannot read another user's connector secrets                  │
└──────────────────────────────────────────────────────────────────┘
```

## 4. Asset inventory

| Asset | Where it lives | Sensitivity |
|---|---|---|
| Slack user token (xoxp/xoxb) | Keychain, service `claude-bar-mcp:<n>:slack` | High |
| ClickUp personal API token (`pk_*`) | Keychain, service `claude-bar-mcp:<n>:clickup` | High |
| Google OAuth refresh token + short-lived access token | Keychain, service `claude-bar-mcp:<n>:gdrive` | High |
| Connector metadata (enabled flag, workspace name, scopes, email, lastVerified) | `registry.json` → `accounts[n].mcpConnectors` | Low — must contain **no secrets** |
| Tool-call requests + responses | Claude.ai chat history (synced) | Medium — outside our control |
| Gateway stderr logs | Console / log file (TBD) | Must be redaction-safe |

## 5. Storage rules

### Allowed

- macOS Keychain generic-password entries, service-name `claude-bar-mcp:<account-number>:<service>`, account = `$USER`.
- Registry JSON metadata (no secrets, only display/status fields).
- In-process memory for the lifetime of one MCP tool call.

### Forbidden

- Repo files, including `.mcp.json` checked into any project.
- Claude Code project-scope MCP config (project-shared `.mcp.json`).
- Claude.ai cloud connectors.
- iCloud sync bundle. Cloud-sync code (`backend/internal/adapter/cloudsync`) MUST exclude `mcpConnectors` metadata and MUST NOT touch the Keychain `claude-bar-mcp:*` namespace.
- Plain-text dumps via `csw verify`, `csw list`, or any `--json` output.
- Anywhere logging is enabled (`Console.app`, file logs, stderr).

## 6. Naming convention (load-bearing)

| Surface | Pattern | Reason |
|---|---|---|
| Keychain service | `claude-bar-mcp:<account-number>:<service>` | Account **number** (not email) survives rename. |
| Keychain account | `$USER` | Same as existing `csw-backup:*` pattern. |
| MCP tool name | `cb_<service>_<verb>` | `cb_` prefix avoids collision with other MCP servers Claude Code may have installed. |
| Registry key | `accounts[n].mcpConnectors.<service>` | One slot per service per account. |
| MCP config entry in Claude Code | `claude-bar-mcp` | Stable name for idempotent install. |

## 7. Resolution model

Active-account is resolved **once per MCP tool call**. No cross-call cache.

- `tools/call` handler reads `registry.json` (already a cheap atomic read).
- Looks up the active account number.
- Builds a per-call connector profile from Keychain.
- Releases the profile when the call returns.

This avoids the race where a user switches account mid-session and gets stale
credentials. Switch latency cost is one file read per call, which is negligible
relative to remote API latency.

## 8. Failure modes

| Condition | Behavior | Rationale |
|---|---|---|
| No active account | Return MCP error `connector_unavailable: no active Claude Bar account`. | Fail closed. |
| Service not enabled for active account | Return `connector_disabled: <service>`. No detail. | Don't leak which other accounts have it. |
| Keychain read fails (item missing) | Return `connector_unavailable: <service> not authorized`. | Don't expose Keychain error to caller. |
| Token rejected by provider | Return `connector_auth_expired: <service>` + mark `needsReauth=true` in registry metadata. | Drives UI re-auth prompt. |
| Rate limit | Return `connector_rate_limited: retry after Ns`. | Standard MCP error. |

## 9. Logging redaction rules

- NEVER log Authorization headers, refresh tokens, access tokens, raw Keychain payloads.
- File IDs, channel IDs, task IDs may be logged at debug level only; default level redacts to length + prefix (`C0123…` for Slack channel IDs).
- Provider error bodies are scrubbed by a redactor that replaces any value matching token-shaped regexes (`xox[abprs]-[A-Za-z0-9-]+`, `pk_[A-Za-z0-9]+`, `ya29\.[A-Za-z0-9_-]+`, etc.) with `[REDACTED]`.
- Default log level: WARN. Debug logging is opt-in via env var, gated against production builds.

## 10. Provider scopes (minimum-viable)

### Slack — user-token paste flow (MVP)

- Required scopes: `channels:history`, `channels:read`, `groups:history`, `groups:read`, `im:history`, `mpim:history`, `search:read`.
- No `chat:write`, no `files:write`, no admin scopes. (Write tools are out of MVP scope.)

### ClickUp — personal API token

- ClickUp personal tokens have account-wide scope; there is no scope subset.
- Mitigation: read-only tools only in MVP; UI copy must warn the user that the
  token can read all workspaces the user has access to.

### Google Drive — OAuth loopback + PKCE

- Required scope: `https://www.googleapis.com/auth/drive.readonly`.
- No `drive.file`, no `drive` (full), no Docs API write scope.
- Refresh token stored; access token refreshed on-demand inside the gateway.

## 11. Disconnect / revoke behavior

- "Disconnect" in widget UI MUST:
  1. Delete Keychain item.
  2. Remove `accounts[n].mcpConnectors.<service>` from registry.
  3. Best-effort: call provider revoke endpoint (Google `revoke`, Slack `auth.revoke`). Skip on ClickUp (no per-token revoke).
- "Remove account" (existing `csw remove` flow) MUST cascade-delete all `claude-bar-mcp:<n>:*` Keychain entries for that account number.

## 12. UI privacy copy (mandatory)

The Local MCP settings panel must show a persistent note. Approved wording:

> Local MCP keeps your Slack / ClickUp / Google Drive tokens on this Mac, tied
> to your active Claude Bar account. Tools and their results still flow through
> your Claude account's chat history, which may be shared if you share that
> Claude login. Switching Claude Bar accounts switches which tokens the local
> gateway uses.

## 13. Out-of-scope risks (accepted)

- macOS user account compromise → connector tokens compromised. Accepted; this matches the existing risk model for `csw-backup:*` Keychain items.
- Claude.ai chat history exposure across devices logged into the same Claude account → outside this feature's control. UI copy must state this explicitly.
- A malicious MCP server installed by the user alongside `claude-bar-mcp` could prompt-inject Claude into requesting our tools with attacker-supplied args. Mitigation: tool argument validation + read-only MVP limits blast radius.

## 14. Open questions

- Slack OAuth app registration vs token-paste for MVP. Token-paste is friction-light but ties user to manually scoping their own app; OAuth app would need a registered Slack app and admin consent at some workspaces.
