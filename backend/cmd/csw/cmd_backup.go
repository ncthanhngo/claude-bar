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

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	bkp "github.com/soi/claude-swap-widget/backend/internal/adapter/backup"
	sshadp "github.com/soi/claude-swap-widget/backend/internal/adapter/ssh"
)

// runBackup dispatches `csw backup <sub>`. Read subcommands (list/get/generate/
// preflight/status/snapshots) are unauthenticated; mutating ones (save/install/
// run/restore/uninstall/rclone-*) are gated by the widget's confirm sheet before
// the call is ever made — same trust model as `csw ssh`.
func runBackup(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw backup <list|get|save|remove|generate|preflight|install|run|status|snapshots|restore|uninstall|rclone-list-drives|rclone-create-remote>")
	}
	sub, rest := args[0], args[1:]
	orch := newOrchestrator()
	switch sub {
	case "list":
		return backupList(ctx, orch)
	case "get":
		return backupGet(ctx, orch, rest)
	case "save":
		return backupSave(ctx, orch)
	case "remove":
		return backupRemove(ctx, orch, rest)
	case "generate":
		return backupGenerate(ctx, orch, rest)
	case "preflight":
		return backupSimple(ctx, rest, func(id string) (any, error) { return orch.Preflight(ctx, id) })
	case "install":
		return backupInstall(ctx, orch, rest)
	case "run":
		return backupSimple(ctx, rest, func(id string) (any, error) { return orch.RunNow(ctx, id) })
	case "status":
		return backupSimple(ctx, rest, func(id string) (any, error) { return orch.Status(ctx, id) })
	case "snapshots":
		return backupSimple(ctx, rest, func(id string) (any, error) { return orch.Snapshots(ctx, id) })
	case "restore":
		return backupRestore(ctx, orch, rest)
	case "uninstall":
		return backupUninstall(ctx, orch, rest)
	case "rclone-list-drives":
		return backupRcloneListDrives(ctx, orch, rest)
	case "rclone-create-remote":
		return backupRcloneCreateRemote(ctx, orch, rest)
	default:
		return fmt.Errorf("unknown backup subcommand: %s", sub)
	}
}

func newOrchestrator() *bkp.Orchestrator {
	return &bkp.Orchestrator{
		Profiles: bkp.NewProfileStore(filepath.Join(adapter.WidgetDataDir(), "backups", "profiles.json")),
		Hosts:    sshadp.NewHostStore(filepath.Join(adapter.WidgetDataDir(), "ssh", "hosts.json")),
		Exec:     sshadp.Exec,
	}
}

func backupList(ctx context.Context, o *bkp.Orchestrator) error {
	profiles, err := o.Profiles.List(ctx)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(profiles)
}

func backupGet(ctx context.Context, o *bkp.Orchestrator, args []string) error {
	id := flagID(args)
	if id == "" {
		return errors.New("--id is required")
	}
	p, err := o.Profiles.Get(ctx, id)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(p)
}

func backupSave(ctx context.Context, o *bkp.Orchestrator) error {
	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		return err
	}
	var p bkp.BackupProfile
	if err := json.Unmarshal(raw, &p); err != nil {
		return fmt.Errorf("decode profile from stdin: %w", err)
	}
	saved, err := o.Profiles.Save(ctx, p)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(saved)
}

func backupRemove(ctx context.Context, o *bkp.Orchestrator, args []string) error {
	id := flagID(args)
	if id == "" {
		return errors.New("--id is required")
	}
	if err := o.Profiles.Delete(ctx, id); err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]bool{"ok": true})
}

func backupGenerate(ctx context.Context, o *bkp.Orchestrator, args []string) error {
	id := flagID(args)
	if id == "" {
		return errors.New("--id is required")
	}
	art, err := o.Generate(ctx, id)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(art)
}

func backupInstall(ctx context.Context, o *bkp.Orchestrator, args []string) error {
	id := flagID(args)
	if id == "" {
		return errors.New("--id is required")
	}
	if err := o.Install(ctx, id); err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]bool{"installed": true})
}

func backupUninstall(ctx context.Context, o *bkp.Orchestrator, args []string) error {
	id := flagID(args)
	if id == "" {
		return errors.New("--id is required")
	}
	if err := o.Uninstall(ctx, id); err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]bool{"uninstalled": true})
}

func backupRestore(ctx context.Context, o *bkp.Orchestrator, args []string) error {
	fs := flag.NewFlagSet("backup-restore", flag.ExitOnError)
	id := fs.String("id", "", "profile id")
	snap := fs.String("snapshot", "", "tier/file to restore")
	_ = fs.Parse(args)
	if *id == "" || *snap == "" {
		return errors.New("--id and --snapshot are required")
	}
	res, err := o.Restore(ctx, *id, *snap)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(res)
}

func backupRcloneListDrives(ctx context.Context, o *bkp.Orchestrator, args []string) error {
	id := flagID(args)
	if id == "" {
		return errors.New("--id is required")
	}
	token, err := io.ReadAll(os.Stdin)
	if err != nil {
		return err
	}
	res, err := o.RcloneListDrives(ctx, id, string(token))
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(res)
}

func backupRcloneCreateRemote(ctx context.Context, o *bkp.Orchestrator, args []string) error {
	fs := flag.NewFlagSet("backup-rclone-create", flag.ExitOnError)
	id := fs.String("id", "", "profile id")
	remote := fs.String("remote", "", "remote name to create")
	drive := fs.String("drive-id", "", "SharePoint drive id")
	_ = fs.Parse(args)
	if *id == "" || *remote == "" || *drive == "" {
		return errors.New("--id, --remote and --drive-id are required")
	}
	token, err := io.ReadAll(os.Stdin)
	if err != nil {
		return err
	}
	res, err := o.RcloneCreateRemote(ctx, *id, *remote, string(token), *drive)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(res)
}

// backupSimple handles the id-only commands that return JSON.
func backupSimple(ctx context.Context, args []string, fn func(id string) (any, error)) error {
	id := flagID(args)
	if id == "" {
		return errors.New("--id is required")
	}
	out, err := fn(id)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(out)
}

func flagID(args []string) string {
	fs := flag.NewFlagSet("backup-id", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	id := fs.String("id", "", "profile id")
	_ = fs.Parse(args)
	return *id
}
