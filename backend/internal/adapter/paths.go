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

// UsageCacheFile returns the usage API response cache.
func UsageCacheFile() string {
	return filepath.Join(WidgetDataDir(), "usage-cache.json")
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
