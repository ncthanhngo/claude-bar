package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	sshadp "github.com/soi/claude-swap-widget/backend/internal/adapter/ssh"
)

// runSSH dispatches `csw ssh <list|add|remove|import>`. The widget
// Diagnostics SSH card calls these. Read-only ops are unauthenticated;
// no token is required because data lives under the user's macOS account.
func runSSH(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw ssh <list|add|remove|import>")
	}
	sub, rest := args[0], args[1:]
	store := sshHostStoreLazy()
	switch sub {
	case "list":
		return runSSHList(ctx, store)
	case "add":
		return runSSHAdd(ctx, store, rest)
	case "remove":
		return runSSHRemove(ctx, store, rest)
	case "import":
		return runSSHImport(ctx, store, rest)
	default:
		return fmt.Errorf("unknown ssh subcommand: %s", sub)
	}
}

func sshHostStoreLazy() *sshadp.HostStore {
	return sshadp.NewHostStore(filepath.Join(adapter.WidgetDataDir(), "ssh", "hosts.json"))
}

func runSSHList(ctx context.Context, store *sshadp.HostStore) error {
	hosts, err := store.List(ctx)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(hosts)
}

func runSSHAdd(ctx context.Context, store *sshadp.HostStore, args []string) error {
	fs := flag.NewFlagSet("ssh-add", flag.ExitOnError)
	name := fs.String("name", "", "host display name")
	hostName := fs.String("host", "", "hostname or IP")
	port := fs.Int("port", 0, "ssh port")
	user := fs.String("user", "", "ssh user")
	id := fs.String("identity", "", "identity file path")
	jump := fs.String("jump", "", "proxy jump host")
	note := fs.String("note", "", "free-text note")
	_ = fs.Parse(args)
	if *name == "" {
		return errors.New("--name is required")
	}
	return store.Put(ctx, sshadp.TrackedHost{
		Name: *name, HostName: *hostName, Port: *port,
		User: *user, IdentityFile: *id, JumpHost: *jump, Note: *note,
		AddedAt: time.Now().UTC(),
	})
}

func runSSHRemove(ctx context.Context, store *sshadp.HostStore, args []string) error {
	fs := flag.NewFlagSet("ssh-remove", flag.ExitOnError)
	name := fs.String("name", "", "host name to remove")
	_ = fs.Parse(args)
	if *name == "" {
		return errors.New("--name is required")
	}
	return store.Delete(ctx, *name)
}

func runSSHImport(ctx context.Context, store *sshadp.HostStore, args []string) error {
	fs := flag.NewFlagSet("ssh-import", flag.ExitOnError)
	path := fs.String("config", "~/.ssh/config", "path to ssh config")
	_ = fs.Parse(args)
	hosts, err := sshadp.ParseSSHConfig(*path)
	if err != nil {
		return fmt.Errorf("parse %s: %w", *path, err)
	}
	added, err := store.MergeFromConfig(ctx, hosts)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"added": added, "parsed": len(hosts), "tracked": len(added),
	})
}
