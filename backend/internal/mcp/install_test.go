package mcp

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/claudeconfig"
)

func TestInstallAddsEntryAndPreservesUnrelated(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".claude.json")
	store := claudeconfig.NewAt(path)
	ctx := context.Background()

	// Seed unrelated fields.
	cfg, _ := store.Read(ctx)
	if cfg.Raw == nil {
		cfg.Raw = map[string]any{}
	}
	cfg.Raw["userID"] = "u-1"
	cfg.Raw["telemetry"] = true
	if err := store.Write(ctx, cfg); err != nil {
		t.Fatalf("seed: %v", err)
	}

	if err := Install(ctx, store, "/Applications/ClaudeBar.app/Contents/Resources/csw", false); err != nil {
		t.Fatalf("install: %v", err)
	}

	got, _ := store.Read(ctx)
	if got.Raw["userID"] != "u-1" || got.Raw["telemetry"] != true {
		t.Fatalf("unrelated fields lost: %+v", got.Raw)
	}
	servers, _ := got.Raw["mcpServers"].(map[string]any)
	entry, _ := servers[MCPConfigEntryName].(map[string]any)
	if entry == nil || entry["command"] != "/Applications/ClaudeBar.app/Contents/Resources/csw" {
		t.Fatalf("entry not installed correctly: %+v", entry)
	}
}

func TestInstallRefusesConflictWithoutForce(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".claude.json")
	store := claudeconfig.NewAt(path)
	ctx := context.Background()

	cfg, _ := store.Read(ctx)
	cfg.Raw = map[string]any{
		"mcpServers": map[string]any{
			MCPConfigEntryName: map[string]any{
				"command": "/some/other/binary",
				"args":    []any{"--weird"},
			},
		},
	}
	if err := store.Write(ctx, cfg); err != nil {
		t.Fatalf("seed: %v", err)
	}

	err := Install(ctx, store, "/Applications/ClaudeBar.app/Contents/Resources/csw", false)
	if err == nil {
		t.Fatal("expected conflict error, got nil")
	}

	if err := Install(ctx, store, "/Applications/ClaudeBar.app/Contents/Resources/csw", true); err != nil {
		t.Fatalf("force install: %v", err)
	}
	got, _ := store.Read(ctx)
	servers, _ := got.Raw["mcpServers"].(map[string]any)
	entry, _ := servers[MCPConfigEntryName].(map[string]any)
	if entry["command"] != "/Applications/ClaudeBar.app/Contents/Resources/csw" {
		t.Fatalf("force did not overwrite: %+v", entry)
	}
}

func TestInstallRefusesSameCommandWithDifferentArgsWithoutForce(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".claude.json")
	store := claudeconfig.NewAt(path)
	ctx := context.Background()

	cfg, _ := store.Read(ctx)
	cfg.Raw = map[string]any{
		"mcpServers": map[string]any{
			MCPConfigEntryName: map[string]any{
				"type":    "stdio",
				"command": "/Applications/ClaudeBar.app/Contents/Resources/csw",
				"args":    []any{"other", "serve"},
			},
		},
	}
	if err := store.Write(ctx, cfg); err != nil {
		t.Fatalf("seed: %v", err)
	}

	err := Install(ctx, store, "/Applications/ClaudeBar.app/Contents/Resources/csw", false)
	if err == nil {
		t.Fatal("expected conflict for same command but unmanaged args")
	}
}

func TestUninstallRemovesEntryAndCleansEmptyMap(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".claude.json")
	store := claudeconfig.NewAt(path)
	ctx := context.Background()

	if err := Install(ctx, store, "/some/csw", false); err != nil {
		t.Fatalf("install: %v", err)
	}
	if err := Uninstall(ctx, store); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	got, _ := store.Read(ctx)
	if _, ok := got.Raw["mcpServers"]; ok {
		t.Fatalf("expected mcpServers key removed when empty, got %+v", got.Raw)
	}
}

func TestStatusReportsInstalled(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".claude.json")
	store := claudeconfig.NewAt(path)
	ctx := context.Background()

	st, err := Status(ctx, store)
	if err != nil || st.Installed {
		t.Fatalf("expected not installed, got %+v err=%v", st, err)
	}
	_ = Install(ctx, store, "/some/csw", false)
	st, err = Status(ctx, store)
	if err != nil || !st.Installed || st.Command != "/some/csw" {
		t.Fatalf("status after install: %+v err=%v", st, err)
	}
}

func TestStatusReportsConflictForUnmanagedEntry(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".claude.json")
	store := claudeconfig.NewAt(path)
	ctx := context.Background()

	cfg, _ := store.Read(ctx)
	cfg.Raw = map[string]any{
		"mcpServers": map[string]any{
			MCPConfigEntryName: map[string]any{
				"type":    "stdio",
				"command": "/some/csw",
				"args":    []any{"unexpected"},
			},
		},
	}
	if err := store.Write(ctx, cfg); err != nil {
		t.Fatalf("seed: %v", err)
	}

	st, err := Status(ctx, store, "/some/csw")
	if err != nil {
		t.Fatal(err)
	}
	if !st.Installed || !st.Conflict {
		t.Fatalf("expected conflict for unmanaged entry, got %+v", st)
	}
}
