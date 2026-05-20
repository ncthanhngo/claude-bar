package mcp

import (
	"context"
	"errors"
	"fmt"
	"reflect"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// MCPConfigEntryName is the stable key under ~/.claude.json["mcpServers"].
const MCPConfigEntryName = "claude-bar-mcp"

// MCPServerEntry is one row in ~/.claude.json -> mcpServers.
type MCPServerEntry struct {
	Type    string            `json:"type,omitempty"`
	Command string            `json:"command"`
	Args    []string          `json:"args,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
}

// InstallStatus reports whether the local gateway is already wired into
// Claude Code user config.
type InstallStatus struct {
	Installed bool   `json:"installed"`
	Command   string `json:"command,omitempty"`
	Conflict  bool   `json:"conflict,omitempty"`
}

// Status reads ~/.claude.json and reports the current install state.
// If expectedCommand is non-empty and the entry exists with a different
// command string, Conflict is set so the caller can warn.
func Status(ctx context.Context, store port.ClaudeConfigStore, expectedCommand ...string) (*InstallStatus, error) {
	cfg, err := store.Read(ctx)
	if err != nil {
		return nil, err
	}
	servers, _ := cfg.Raw["mcpServers"].(map[string]any)
	entry, ok := servers[MCPConfigEntryName].(map[string]any)
	if !ok {
		return &InstallStatus{Installed: false}, nil
	}
	cmd, _ := entry["command"].(string)
	st := &InstallStatus{Installed: true, Command: cmd}
	if len(expectedCommand) > 0 && expectedCommand[0] != "" {
		st.Conflict = !isManagedEntry(entry, expectedCommand[0])
	}
	return st, nil
}

// Install adds (or refreshes) the claude-bar-mcp entry in ~/.claude.json.
// It preserves every other field in the file. If an entry with the same
// name exists with a different command, returns an error (Conflict) unless
// force=true.
func Install(ctx context.Context, store port.ClaudeConfigStore, cswPath string, force bool) error {
	cfg, err := store.Read(ctx)
	if err != nil {
		return err
	}
	if cfg.Raw == nil {
		cfg.Raw = map[string]any{}
	}
	servers, _ := cfg.Raw["mcpServers"].(map[string]any)
	if servers == nil {
		servers = map[string]any{}
	}
	if existing, ok := servers[MCPConfigEntryName].(map[string]any); ok && !force {
		if !isManagedEntry(existing, cswPath) {
			return fmt.Errorf("mcp install: an entry named %q already exists but is not the Claude Bar managed entry. Re-run with --force to overwrite", MCPConfigEntryName)
		}
	}
	servers[MCPConfigEntryName] = managedEntry(cswPath)
	cfg.Raw["mcpServers"] = servers
	return store.Write(ctx, cfg)
}

func managedEntry(cswPath string) map[string]any {
	return map[string]any{
		"type":    "stdio",
		"command": cswPath,
		"args":    []string{"mcp", "serve"},
	}
}

func isManagedEntry(entry map[string]any, cswPath string) bool {
	if typ, _ := entry["type"].(string); typ != "stdio" {
		return false
	}
	if cmd, _ := entry["command"].(string); cmd != cswPath {
		return false
	}
	if env, ok := entry["env"]; ok && env != nil {
		return false
	}
	return reflect.DeepEqual(normalizeArgs(entry["args"]), []string{"mcp", "serve"})
}

func normalizeArgs(v any) []string {
	switch xs := v.(type) {
	case []string:
		return xs
	case []any:
		out := make([]string, 0, len(xs))
		for _, x := range xs {
			s, ok := x.(string)
			if !ok {
				return nil
			}
			out = append(out, s)
		}
		return out
	default:
		return nil
	}
}

// Uninstall removes the claude-bar-mcp entry. No-op if not present.
func Uninstall(ctx context.Context, store port.ClaudeConfigStore) error {
	cfg, err := store.Read(ctx)
	if err != nil {
		return err
	}
	servers, _ := cfg.Raw["mcpServers"].(map[string]any)
	if servers == nil {
		return nil
	}
	if _, ok := servers[MCPConfigEntryName]; !ok {
		return nil
	}
	delete(servers, MCPConfigEntryName)
	if len(servers) == 0 {
		delete(cfg.Raw, "mcpServers")
	} else {
		cfg.Raw["mcpServers"] = servers
	}
	return store.Write(ctx, cfg)
}

// ErrAlreadyInstalled is returned by Install when an unrelated entry exists.
var ErrAlreadyInstalled = errors.New("claude-bar-mcp already installed with a different command")
