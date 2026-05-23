// Package adapter holds I/O implementations of the ports.
package adapter

import (
	"os"
	"path/filepath"
)

// ClaudeConfigDir returns ~/.claude (or $CLAUDE_CONFIG_DIR override).
func ClaudeConfigDir() string {
	if v := os.Getenv("CLAUDE_CONFIG_DIR"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude")
}

// ClaudeConfigFile returns ~/.claude.json.
func ClaudeConfigFile() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude.json")
}

// ClaudeSessionsDir returns ~/.claude/sessions.
func ClaudeSessionsDir() string {
	return filepath.Join(ClaudeConfigDir(), "sessions")
}

// ClaudeProjectsDir returns ~/.claude/projects, where Claude Code (CLI + IDE
// extensions) stores per-project JSONL conversation logs that include token
// usage per assistant message.
func ClaudeProjectsDir() string {
	return filepath.Join(ClaudeConfigDir(), "projects")
}

// WidgetDataDir returns ~/Library/Application Support/claude-swap-widget on macOS.
func WidgetDataDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "claude-swap-widget")
}

// RegistryFile returns the path to the widget registry JSON.
func RegistryFile() string {
	return filepath.Join(WidgetDataDir(), "registry.json")
}

// LockFile returns the cross-process lock file path.
func LockFile() string {
	return filepath.Join(WidgetDataDir(), "swap.lock")
}

// GateSocketFile returns the Unix domain socket path that the MCP server
// uses to talk to the widget for write-gate approvals.
func GateSocketFile() string {
	return filepath.Join(WidgetDataDir(), "gate.sock")
}

// AuditLogFile returns the canonical append-only audit log path.
func AuditLogFile() string {
	return filepath.Join(WidgetDataDir(), "audit.log")
}

// UsageCacheFile returns the usage API response cache.
func UsageCacheFile() string {
	return filepath.Join(WidgetDataDir(), "usage-cache.json")
}

// PricingCacheFile holds the most recent pricing snapshot fetched from the
// hosted JSON (raw.githubusercontent.com). On launch the pricing provider
// loads this if present so the app can show last-known rates while a fresh
// fetch runs in the background. Validated before write, so a corrupt file
// won't poison the cache.
func PricingCacheFile() string {
	return filepath.Join(WidgetDataDir(), "pricing-cache.json")
}

// CloudSyncStateFile holds per-device sync state (seq + bundle hash) for
// anti-rollback. Local-only — never synced.
func CloudSyncStateFile() string {
	return filepath.Join(WidgetDataDir(), "cloud-sync-state.json")
}

// EnsureDataDir creates the widget data dir with safe perms.
func EnsureDataDir() error {
	return os.MkdirAll(WidgetDataDir(), 0o700)
}

// ChatRootDir is the parent dir for all per-account chat data.
// ~/Library/Application Support/claude-swap-widget/chat/
func ChatRootDir() string {
	return filepath.Join(WidgetDataDir(), "chat")
}

// ChatAccountDir returns the per-account dir that holds the SQLCipher DB and
// the attachments subdir. accountUUID is treated opaque — callers must pass
// a sanitised identifier (OAuthAccount.AccountUUID or the registry
// IdentityKey fallback used by oauth.TokenProvider).
func ChatAccountDir(accountUUID string) string {
	return filepath.Join(ChatRootDir(), accountUUID)
}

// ChatDBFile returns the SQLCipher database path for accountUUID.
func ChatDBFile(accountUUID string) string {
	return filepath.Join(ChatAccountDir(accountUUID), "chat.db")
}

// ChatAttachmentDir returns the per-account encrypted-attachment dir.
func ChatAttachmentDir(accountUUID string) string {
	return filepath.Join(ChatAccountDir(accountUUID), "attachments")
}

// BriefingUserPromptFile holds the user-authored markdown prompt the
// briefing runner injects into Claude's prompt as a "# Ưu tiên người
// dùng" section. Widget Settings writes it on change; backend reads it
// on each `csw briefing run`. Missing file = no extra context.
func BriefingUserPromptFile() string {
	return filepath.Join(WidgetDataDir(), "briefing-user-prompt.md")
}

// MCPConnectorPromptsFile holds the per-MCP-connector markdown prompts
// (slack / clickup / gdrive / gmail / gcal / gsheets). JSON-encoded shape
// of the widget's MCPConnectorPrompts struct.
func MCPConnectorPromptsFile() string {
	return filepath.Join(WidgetDataDir(), "mcp-connector-prompts.json")
}

// EnsureChatAccountDir creates the per-account chat + attachments dirs with
// safe perms (0700). Idempotent — used by storage.Open on first launch and
// silently OK if the dirs already exist.
func EnsureChatAccountDir(accountUUID string) error {
	if err := os.MkdirAll(ChatAttachmentDir(accountUUID), 0o700); err != nil {
		return err
	}
	return os.Chmod(ChatAccountDir(accountUUID), 0o700)
}
