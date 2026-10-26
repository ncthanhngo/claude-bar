// Package adapter holds I/O implementations of the ports.
package adapter

import (
	"os"
	"path/filepath"
	"runtime"
)

// windowsAppName names the per-user folders on Windows.
const windowsAppName = "ClaudeSwap"

// ClaudeConfigDir returns ~/.claude (or $CLAUDE_CONFIG_DIR override).
func ClaudeConfigDir() string {
	if v := os.Getenv("CLAUDE_CONFIG_DIR"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude")
}

// ClaudeConfigFile returns the global config file Claude Code reads (and
// where it keeps oauthAccount): <config dir>/.config.json when that legacy
// file is non-empty, else .claude.json in $CLAUDE_CONFIG_DIR or the home
// folder — the same choice Claude Code 2.1.310 makes.
func ClaudeConfigFile() string {
	if info, err := os.Stat(filepath.Join(ClaudeConfigDir(), ".config.json")); err == nil && info.Size() > 0 {
		return filepath.Join(ClaudeConfigDir(), ".config.json")
	}
	dir := os.Getenv("CLAUDE_CONFIG_DIR")
	if dir == "" {
		dir, _ = os.UserHomeDir()
	}
	return filepath.Join(dir, ".claude.json")
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

// WidgetDataDir returns ~/Library/Application Support/claude-swap-widget on
// macOS and %APPDATA%\ClaudeSwap on Windows.
func WidgetDataDir() string {
	if runtime.GOOS == "windows" {
		dir, _ := os.UserConfigDir()
		return filepath.Join(dir, windowsAppName)
	}
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

// BackupRefreshLockFile serialises backup token refreshes across csw
// processes. Separate from LockFile: a swap holds that lock while it may
// refresh the target's backup.
func BackupRefreshLockFile() string {
	return filepath.Join(WidgetDataDir(), "refresh.lock")
}

// CswLogFile is the credential event log, next to the widget's own log
// (%LOCALAPPDATA%\ClaudeSwap\logs on Windows).
func CswLogFile() string {
	if runtime.GOOS == "windows" {
		dir, _ := os.UserCacheDir()
		return filepath.Join(dir, windowsAppName, "logs", "csw.log")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Logs", "ClaudeBar", "csw.log")
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

// MCPWritePolicyFile holds local write-gate policy toggles controlled by the
// widget UI. Missing or invalid file means every write tool remains gated.
func MCPWritePolicyFile() string {
	return filepath.Join(WidgetDataDir(), "mcp-write-policy.json")
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
