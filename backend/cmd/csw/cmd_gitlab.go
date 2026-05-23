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

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/keychain"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/mcp"
)

// runGitLab dispatches `csw gitlab <list|add|remove>`. The widget
// Diagnostics GitLab card uses this. PATs come on stdin; never in argv.
func runGitLab(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw gitlab <list|add|remove>")
	}
	store := mcp.NewGitLabInstanceStore(filepath.Join(adapter.WidgetDataDir(), "gitlab-instances.json"))
	switch args[0] {
	case "list":
		return runGitLabList(ctx, store)
	case "add":
		return runGitLabAdd(ctx, store, args[1:])
	case "remove":
		return runGitLabRemove(ctx, store, args[1:])
	default:
		return fmt.Errorf("unknown gitlab subcommand: %s", args[0])
	}
}

func runGitLabList(ctx context.Context, store *mcp.GitLabInstanceStore) error {
	insts, err := store.List(ctx)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(insts)
}

func runGitLabAdd(ctx context.Context, store *mcp.GitLabInstanceStore, args []string) error {
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
	return json.NewEncoder(os.Stdout).Encode(saved)
}

func runGitLabRemove(ctx context.Context, store *mcp.GitLabInstanceStore, args []string) error {
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
	return nil
}
