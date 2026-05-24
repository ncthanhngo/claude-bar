package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/repomap"
)

// runRepomap dispatches `csw repomap <scan|lookup|list>`. The widget calls
// scan once on first launch (or after the user edits the roots list) and
// lookup any time the "Ask Claude about this PR" path needs an on-disk
// checkout.
func runRepomap(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw repomap <scan|lookup|list>")
	}
	switch args[0] {
	case "scan":
		return runRepomapScan(ctx, args[1:])
	case "lookup":
		return runRepomapLookup(ctx, args[1:])
	case "list":
		return runRepomapList(ctx)
	default:
		return fmt.Errorf("unknown repomap subcommand: %s", args[0])
	}
}

func repomapFile() string {
	return filepath.Join(adapter.WidgetDataDir(), "repo-map.json")
}

func defaultRoots() []string {
	return []string{"~/Project", "~/dev", "~/Code", "~/src"}
}

func runRepomapScan(_ context.Context, args []string) error {
	fs := flag.NewFlagSet("repomap-scan", flag.ExitOnError)
	rootsCSV := fs.String("roots", "", "comma-separated root dirs (default: ~/Project, ~/dev, ~/Code, ~/src)")
	depth := fs.Int("depth", 2, "max scan depth per root")
	_ = fs.Parse(args)

	roots := defaultRoots()
	if *rootsCSV != "" {
		roots = nil
		for _, r := range strings.Split(*rootsCSV, ",") {
			if t := strings.TrimSpace(r); t != "" {
				roots = append(roots, t)
			}
		}
	}
	if err := adapter.EnsureDataDir(); err != nil {
		return err
	}
	m, err := repomap.Scanner{Roots: roots, MaxDepth: *depth}.Scan()
	if err != nil {
		return err
	}
	if err := m.Save(repomapFile()); err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"entries": len(m.Entries),
		"roots":   m.Roots,
	})
}

func runRepomapLookup(_ context.Context, args []string) error {
	fs := flag.NewFlagSet("repomap-lookup", flag.ExitOnError)
	origin := fs.String("origin", "", "origin URL to resolve")
	_ = fs.Parse(args)
	if *origin == "" {
		return errors.New("--origin is required")
	}
	m, err := repomap.Load(repomapFile())
	if err != nil {
		return err
	}
	if m == nil {
		return json.NewEncoder(os.Stdout).Encode(map[string]any{"localPath": ""})
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"localPath": m.Lookup(*origin),
	})
}

func runRepomapList(_ context.Context) error {
	m, err := repomap.Load(repomapFile())
	if err != nil {
		return err
	}
	if m == nil {
		_, _ = os.Stdout.Write([]byte("[]\n"))
		return nil
	}
	return json.NewEncoder(os.Stdout).Encode(m.Entries)
}
