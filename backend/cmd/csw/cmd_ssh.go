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
	sshadp "github.com/soi/claude-swap-widget/backend/internal/adapter/ssh"
)

// runSSH dispatches `csw ssh <list|add|remove|import>`. The widget
// Diagnostics SSH card calls these. Read-only ops are unauthenticated;
// no token is required because data lives under the user's macOS account.
func runSSH(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw ssh <list|add|update|remove|import|classify|exec|monitor|health>")
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
	case "export-bundle":
		return runSSHExportBundle(ctx, store, rest)
	case "import-bundle":
		return runSSHImportBundle(ctx, store, rest)
	case "classify":
		return runSSHClassify(ctx, rest)
	case "exec":
		return runSSHExec(ctx, store, rest)
	case "monitor":
		return runSSHMonitor(ctx, store, rest)
	case "health":
		return runSSHHealth(ctx, store, rest)
	case "update":
		return runSSHUpdate(ctx, store, rest)
	default:
		return fmt.Errorf("unknown ssh subcommand: %s", sub)
	}
}

// riskLabel maps the ssh adapter's Risk enum to a stable wire string the
// widget reads to decide whether a command runs straight away (low) or needs
// the confirm sheet (medium / destructive).
func riskLabel(r sshadp.Risk) string {
	switch r {
	case sshadp.RiskLow:
		return "low"
	case sshadp.RiskMedium:
		return "medium"
	default:
		return "destructive"
	}
}

// runSSHClassify reads a command on stdin and reports its risk level WITHOUT
// running anything. The widget's server assistant calls this before every
// proposed command so the gate decision uses the same classifier the MCP
// gateway does — one source of truth, the LLM cannot downgrade it.
func runSSHClassify(_ context.Context, _ []string) error {
	cmdBytes, err := io.ReadAll(os.Stdin)
	if err != nil {
		return err
	}
	cmd := strings.TrimSpace(string(cmdBytes))
	if cmd == "" {
		return errors.New("command required on stdin")
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]string{
		"risk": riskLabel(sshadp.ClassifyCmd(cmd)),
	})
}

// runSSHExec runs a single command on a tracked host and prints the
// ExecResult (plus the server-side risk classification) as JSON. The command
// is read from stdin so user / LLM bytes never land in argv or shell history;
// gating happened in the widget's confirm sheet before this is ever called.
func runSSHExec(ctx context.Context, store *sshadp.HostStore, args []string) error {
	fs := flag.NewFlagSet("ssh-exec", flag.ExitOnError)
	hostName := fs.String("host", "", "tracked host name")
	timeoutSec := fs.Int("timeout", 120, "wall-clock cap in seconds (1–600)")
	_ = fs.Parse(args)
	if *hostName == "" {
		return errors.New("--host is required")
	}
	cmdBytes, err := io.ReadAll(os.Stdin)
	if err != nil {
		return err
	}
	cmd := strings.TrimSpace(string(cmdBytes))
	if cmd == "" {
		return errors.New("command required on stdin")
	}
	if *timeoutSec < 1 {
		*timeoutSec = 120
	}
	if *timeoutSec > 600 {
		*timeoutSec = 600
	}

	host, err := store.Get(ctx, *hostName)
	if err != nil {
		return err
	}
	res, err := sshadp.Exec(ctx, *host, cmd, time.Duration(*timeoutSec)*time.Second)
	if err != nil {
		return err
	}
	_ = store.MarkConnected(ctx, *hostName, time.Now().UTC())
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"stdout":     res.Stdout,
		"stderr":     res.Stderr,
		"exitCode":   res.ExitCode,
		"durationMs": res.DurationMs,
		"risk":       riskLabel(sshadp.ClassifyCmd(cmd)),
	})
}

// runSSHMonitor toggles the periodic health probe for a host (opt-in per
// host) and optionally sets which filesystem the disk check runs against.
// Bool flag: pass `--enabled=true` / `--enabled=false` (the flag package does
// not consume a separate arg for bools). Prints the updated host as JSON.
func runSSHMonitor(ctx context.Context, store *sshadp.HostStore, args []string) error {
	fs := flag.NewFlagSet("ssh-monitor", flag.ExitOnError)
	hostName := fs.String("host", "", "tracked host name")
	enabled := fs.Bool("enabled", false, "enable the health probe for this host")
	diskPath := fs.String("disk-path", "", "filesystem for the disk check (default /)")
	_ = fs.Parse(args)
	if *hostName == "" {
		return errors.New("--host is required")
	}
	host, err := store.Get(ctx, *hostName)
	if err != nil {
		return err
	}
	host.Monitor = *enabled
	if *diskPath != "" {
		host.DiskPath = *diskPath
	}
	if err := store.Put(ctx, *host); err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(host)
}

// runSSHHealth probes monitored hosts (or a single --host) and prints a
// []HostHealth JSON array. Reachability + disk% are derived from one `df -P`
// per host; a reachable host has its lastConnected stamp refreshed. Failures
// are encoded per-host (reachable=false), so the array is never partial.
func runSSHHealth(ctx context.Context, store *sshadp.HostStore, args []string) error {
	fs := flag.NewFlagSet("ssh-health", flag.ExitOnError)
	hostName := fs.String("host", "", "probe only this host (default: all monitored)")
	timeoutSec := fs.Int("timeout", 20, "per-host wall-clock cap in seconds (1–120)")
	_ = fs.Parse(args)
	if *timeoutSec < 1 {
		*timeoutSec = 20
	}
	if *timeoutSec > 120 {
		*timeoutSec = 120
	}

	hosts, err := store.List(ctx)
	if err != nil {
		return err
	}
	timeout := time.Duration(*timeoutSec) * time.Second
	out := make([]sshadp.HostHealth, 0, len(hosts))
	for _, h := range hosts {
		if *hostName != "" {
			if h.Name != *hostName {
				continue
			}
		} else if !h.Monitor {
			continue
		}
		hh := sshadp.ProbeHealth(ctx, h, h.DiskPath, timeout)
		if hh.Reachable {
			_ = store.MarkConnected(ctx, h.Name, time.Now().UTC())
		}
		out = append(out, hh)
	}
	return json.NewEncoder(os.Stdout).Encode(out)
}

// runSSHUpdate edits an existing tracked host in place, applying ONLY the
// flags actually passed (detected via fs.Visit) so untouched fields — and the
// monitor flag, addedAt, and lastConnected the caller never sees — are
// preserved. Renaming happens through --display (Label); the Name identity is
// immutable here on purpose (backup profiles / assistant reference it).
func runSSHUpdate(ctx context.Context, store *sshadp.HostStore, args []string) error {
	fs := flag.NewFlagSet("ssh-update", flag.ExitOnError)
	name := fs.String("name", "", "host name (identity, required)")
	display := fs.String("display", "", "display label")
	hostName := fs.String("host", "", "hostname or IP")
	user := fs.String("user", "", "ssh user")
	port := fs.Int("port", 0, "ssh port")
	id := fs.String("identity", "", "private key path")
	jump := fs.String("jump", "", "proxy jump host")
	note := fs.String("note", "", "free-text note")
	diskPath := fs.String("disk-path", "", "filesystem for the disk check")
	_ = fs.Parse(args)
	if *name == "" {
		return errors.New("--name is required")
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })

	h, err := store.Get(ctx, *name)
	if err != nil {
		return err
	}
	if set["display"] {
		h.Label = *display
	}
	if set["host"] {
		h.HostName = *hostName
	}
	if set["user"] {
		h.User = *user
	}
	if set["port"] {
		h.Port = *port
	}
	if set["identity"] {
		h.IdentityFile = *id
	}
	if set["jump"] {
		h.JumpHost = *jump
	}
	if set["note"] {
		h.Note = *note
	}
	if set["disk-path"] {
		h.DiskPath = *diskPath
	}
	if err := store.Put(ctx, *h); err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(h)
}

func runSSHExportBundle(ctx context.Context, store *sshadp.HostStore, args []string) error {
	fs := flag.NewFlagSet("ssh-export-bundle", flag.ExitOnError)
	out := fs.String("out", "", "output .cbssh path")
	_ = fs.Parse(args)
	if *out == "" {
		return errors.New("--out is required")
	}
	passBytes, err := io.ReadAll(os.Stdin)
	if err != nil {
		return err
	}
	pass := strings.TrimSpace(string(passBytes))
	if pass == "" {
		return errors.New("passphrase required on stdin")
	}
	hosts, err := store.List(ctx)
	if err != nil {
		return err
	}
	return sshadp.ExportBundleFile(ctx, hosts, pass, *out)
}

func runSSHImportBundle(ctx context.Context, store *sshadp.HostStore, args []string) error {
	fs := flag.NewFlagSet("ssh-import-bundle", flag.ExitOnError)
	in := fs.String("in", "", "input .cbssh path")
	merge := fs.Bool("merge", true, "merge into existing tracked hosts (false = replace all)")
	_ = fs.Parse(args)
	if *in == "" {
		return errors.New("--in is required")
	}
	passBytes, err := io.ReadAll(os.Stdin)
	if err != nil {
		return err
	}
	pass := strings.TrimSpace(string(passBytes))
	if pass == "" {
		return errors.New("passphrase required on stdin")
	}
	b, err := sshadp.ImportBundleFile(ctx, *in, pass)
	if err != nil {
		return err
	}
	if !*merge {
		// Replace: delete everything currently tracked, then re-Put.
		existing, _ := store.List(ctx)
		for _, h := range existing {
			_ = store.Delete(ctx, h.Name)
		}
	}
	added := 0
	for _, h := range b.Hosts {
		if err := store.Put(ctx, h); err == nil {
			added++
		}
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"imported": added, "total": len(b.Hosts),
	})
}

func sshHostStoreLazy() *sshadp.HostStore {
	return sshadp.NewHostStore(filepath.Join(adapter.WidgetDataDir(), "ssh", "hosts.json"))
}

func runSSHList(ctx context.Context, store *sshadp.HostStore) error {
	hosts, err := store.List(ctx)
	if err != nil {
		return err
	}
	if hosts == nil {
		hosts = []sshadp.TrackedHost{}
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
	display := fs.String("display", "", "display label")
	monitor := fs.Bool("monitor", false, "opt into the health probe")
	diskPath := fs.String("disk-path", "", "filesystem for the disk check (default /)")
	_ = fs.Parse(args)
	if *name == "" {
		return errors.New("--name is required")
	}
	return store.Put(ctx, sshadp.TrackedHost{
		Name: *name, Label: *display, HostName: *hostName, Port: *port,
		User: *user, IdentityFile: *id, JumpHost: *jump, Note: *note,
		Monitor: *monitor, DiskPath: *diskPath,
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
