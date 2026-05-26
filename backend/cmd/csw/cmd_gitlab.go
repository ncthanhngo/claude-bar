package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/keychain"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/mcp"
	"github.com/soi/claude-swap-widget/backend/internal/usecase"
)

// runGitLab dispatches `csw gitlab <list|add|remove>`. The widget
// Diagnostics GitLab card uses this. PATs come on stdin; never in argv.
//
// `svc` is now passed in so `add` / `remove` can also flip the shared
// `MCPServiceGitLab` connector flag in the registry — without that
// mirror, the MCP connectors list in Settings stays stuck at
// "not connected" even after the user successfully adds a GitLab
// instance, because the instance secrets live in a separate
// `gitlab:<id>` Keychain slot the connector summary doesn't read.
func runGitLab(ctx context.Context, svc *usecase.Service, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw gitlab <list|add|remove>")
	}
	store := mcp.NewGitLabInstanceStore(filepath.Join(adapter.WidgetDataDir(), "gitlab-instances.json"))
	switch args[0] {
	case "list":
		return runGitLabList(ctx, store)
	case "add":
		return runGitLabAdd(ctx, svc, store, args[1:])
	case "remove":
		return runGitLabRemove(ctx, svc, store, args[1:])
	default:
		return fmt.Errorf("unknown gitlab subcommand: %s", args[0])
	}
}

func runGitLabList(ctx context.Context, store *mcp.GitLabInstanceStore) error {
	insts, err := store.List(ctx)
	if err != nil {
		return err
	}
	if insts == nil {
		insts = []mcp.GitLabInstance{}
	}
	return json.NewEncoder(os.Stdout).Encode(insts)
}

func runGitLabAdd(ctx context.Context, svc *usecase.Service, store *mcp.GitLabInstanceStore, args []string) error {
	fs := flag.NewFlagSet("gitlab-add", flag.ExitOnError)
	name := fs.String("name", "", "display name")
	baseURL := fs.String("baseurl", "", "https:// base URL incl. /api/v4")
	note := fs.String("note", "", "free-text note")
	_ = fs.Parse(args)
	if *name == "" || *baseURL == "" {
		return errors.New("--name and --baseurl are required")
	}
	patBytes, err := io.ReadAll(os.Stdin)
	if err != nil {
		return err
	}
	pat := strings.TrimSpace(string(patBytes))
	if pat == "" {
		return errors.New("PAT required on stdin")
	}

	saved, err := store.Put(ctx, mcp.GitLabInstance{
		Name: *name, BaseURL: *baseURL, Note: *note,
	})
	if err != nil {
		return err
	}
	// Persist PAT in the multi-token Keychain slot.
	secrets := keychain.NewMCPSecretStore()
	if err := secrets.PutShared(ctx, domain.MCPService("gitlab:"+saved.ID), pat); err != nil {
		return fmt.Errorf("persist gitlab pat: %w", err)
	}
	// Mirror the connection into the shared MCPConnector flag so the
	// Settings → MCP connectors list reflects "GitLab · connected"
	// straight after the user closes the add-instance window. Without
	// this mirror the row stays stuck at "not connected" forever,
	// because the connector summary reads per-service Keychain slots
	// (gitlab) not per-instance ones (gitlab:<id>). Best-effort: a
	// registry-write failure logs but does not roll back the instance
	// — the secret is already saved and removing it on a registry
	// hiccup would lose the PAT.
	if svc != nil {
		mirrorGitLabConnectorEnabled(ctx, svc, saved)
	}
	return json.NewEncoder(os.Stdout).Encode(saved)
}

func runGitLabRemove(ctx context.Context, svc *usecase.Service, store *mcp.GitLabInstanceStore, args []string) error {
	fs := flag.NewFlagSet("gitlab-remove", flag.ExitOnError)
	id := fs.String("id", "", "instance id")
	_ = fs.Parse(args)
	if *id == "" {
		return errors.New("--id is required")
	}
	if err := store.Delete(ctx, *id); err != nil {
		return err
	}
	secrets := keychain.NewMCPSecretStore()
	_ = secrets.Write(ctx, 0, domain.MCPService("gitlab:"+*id), "")
	// If this was the last GitLab instance, clear the shared connector
	// flag so the Settings UI flips back to "not connected".
	if svc != nil {
		if remaining, err := store.List(ctx); err == nil && len(remaining) == 0 {
			clearGitLabConnectorMirror(ctx, svc)
		}
	}
	return nil
}

func mirrorGitLabConnectorEnabled(ctx context.Context, svc *usecase.Service, inst mcp.GitLabInstance) {
	if err := svc.Lock.Acquire(ctx); err != nil {
		return
	}
	defer svc.Lock.Release()
	reg, err := svc.Registry.Load(ctx)
	if err != nil {
		return
	}
	if reg.SharedMCPConnectors == nil {
		reg.SharedMCPConnectors = domain.AccountConnectors{}
	}
	existing := reg.SharedMCPConnectors[domain.MCPServiceGitLab]
	if existing == nil {
		existing = &domain.MCPConnector{}
	}
	existing.Enabled = true
	if existing.DisplayName == "" {
		existing.DisplayName = inst.Name
	}
	if existing.ConnectedAt.IsZero() {
		existing.ConnectedAt = time.Now().UTC()
	}
	reg.SharedMCPConnectors[domain.MCPServiceGitLab] = existing
	_ = svc.Registry.Save(ctx, reg)
}

func clearGitLabConnectorMirror(ctx context.Context, svc *usecase.Service) {
	if err := svc.Lock.Acquire(ctx); err != nil {
		return
	}
	defer svc.Lock.Release()
	reg, err := svc.Registry.Load(ctx)
	if err != nil {
		return
	}
	if reg.SharedMCPConnectors != nil {
		delete(reg.SharedMCPConnectors, domain.MCPServiceGitLab)
		if len(reg.SharedMCPConnectors) == 0 {
			reg.SharedMCPConnectors = nil
		}
		_ = svc.Registry.Save(ctx, reg)
	}
}
