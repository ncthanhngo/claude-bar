package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/ollama"
	"github.com/soi/claude-swap-widget/backend/internal/port"
	"github.com/soi/claude-swap-widget/backend/internal/usecase"
)

// runNews dispatches `csw news <show|fetch|config|providers|publish|pull>`.
// Every subcommand always prints JSON (the --json flag is accepted for
// consistency with the rest of the CLI but the news surface has no
// human-readable mode — the widget is the only caller).
func runNews(ctx context.Context, svc *usecase.Service, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw news <show|fetch|config|providers|publish|pull>")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "show":
		return runNewsShow(ctx, svc, rest)
	case "fetch":
		return runNewsFetch(ctx, svc, rest)
	case "config":
		return runNewsConfig(ctx, svc, rest)
	case "providers":
		return runNewsProviders(ctx, svc, rest)
	case "publish":
		return runNewsPublish(ctx, svc, rest)
	case "pull":
		return runNewsPull(ctx, svc, rest)
	default:
		return fmt.Errorf("unknown news subcommand: %s", sub)
	}
}

// runNewsShow returns the last persisted snapshot — fast, no network.
func runNewsShow(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("news-show", flag.ExitOnError)
	_ = fs.Bool("json", false, "machine-readable output (always on for this command)")
	_ = fs.Parse(args)

	feed, err := svc.NewsStore.LoadFeed(ctx)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(feed)
}

// runNewsFetch aggregates now (feeds + repos + AI), persists, and returns
// the fresh NewsFeed. --force is accepted for CLI-surface parity with the
// plan but is a no-op today — v1 has no cache to bypass; every fetch is
// already a live aggregation run.
func runNewsFetch(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("news-fetch", flag.ExitOnError)
	_ = fs.Bool("force", false, "ignored — fetch always aggregates fresh (no cache in v1)")
	_ = fs.Bool("json", false, "machine-readable output (always on for this command)")
	_ = fs.Parse(args)

	cfg, err := svc.NewsStore.LoadConfig(ctx)
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	feed, err := svc.NewsAggregator.Fetch(ctx, *cfg)
	if err != nil {
		return fmt.Errorf("fetch: %w", err)
	}
	if err := svc.NewsStore.SaveFeed(ctx, feed); err != nil {
		return fmt.Errorf("persist: %w", err)
	}
	return json.NewEncoder(os.Stdout).Encode(feed)
}

func runNewsConfig(ctx context.Context, svc *usecase.Service, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw news config <get|set>")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "get":
		return runNewsConfigGet(ctx, svc, rest)
	case "set":
		return runNewsConfigSet(ctx, svc, rest)
	default:
		return fmt.Errorf("unknown news config subcommand: %s", sub)
	}
}

func runNewsConfigGet(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("news-config-get", flag.ExitOnError)
	_ = fs.Bool("json", false, "machine-readable output (always on for this command)")
	_ = fs.Parse(args)

	cfg, err := svc.NewsStore.LoadConfig(ctx)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(cfg)
}

// runNewsConfigSet reads a full NewsConfig JSON body on stdin and persists
// it verbatim — Go's config.json is the authority; the widget always
// round-trips a full object rather than patching individual fields.
func runNewsConfigSet(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("news-config-set", flag.ExitOnError)
	_ = fs.Bool("json", false, "machine-readable output (always on for this command)")
	_ = fs.Parse(args)

	body, err := io.ReadAll(os.Stdin)
	if err != nil {
		return fmt.Errorf("read stdin: %w", err)
	}
	var cfg port.NewsConfig
	if err := json.Unmarshal(body, &cfg); err != nil {
		return fmt.Errorf("parse config JSON: %w", err)
	}
	if err := validateNewsConfig(cfg); err != nil {
		return err
	}
	if err := svc.NewsStore.SaveConfig(ctx, &cfg); err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(&cfg)
}

// validateNewsConfig rejects a config set that would leave aggregation with
// no usable provider or a malformed feed — the earliest point to catch a
// widget bug or a mistyped provider string, rather than failing deep
// inside Fetch.
func validateNewsConfig(cfg port.NewsConfig) error {
	switch cfg.Provider {
	case "ollama", "claude":
	default:
		return fmt.Errorf("invalid provider %q: must be \"ollama\" or \"claude\"", cfg.Provider)
	}
	for _, f := range cfg.Feeds {
		if f.Mode != port.FeedModeRSS && f.Mode != port.FeedModeAISummary {
			return fmt.Errorf("feed %q: invalid mode %q", f.Label, f.Mode)
		}
	}
	return nil
}

// runNewsProviders reports Ollama reachability + installed models, and
// whether a Claude fallback account is available, so the widget can
// populate the provider/model picker without running a full fetch.
func runNewsProviders(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("news-providers", flag.ExitOnError)
	_ = fs.Bool("json", false, "machine-readable output (always on for this command)")
	_ = fs.Parse(args)

	client := ollama.NewClient()
	models, err := client.ListModels(ctx)
	ollamaAvailable := err == nil
	if models == nil {
		models = []string{}
	}

	claudeAvailable := false
	if reg, err := svc.Registry.Load(ctx); err == nil {
		claudeAvailable = reg.ActiveAccountNumber != 0
	}

	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"providers":       []string{"ollama", "claude"},
		"ollamaModels":    models,
		"ollamaAvailable": ollamaAvailable,
		"claudeAvailable": claudeAvailable,
	})
}

// runNewsPublish pushes the local news.json snapshot + manifest to a shared
// SSH relay host — a Master machine calls this after a successful `news
// fetch` so Client machines can pull an identical page. Prints {"ok":true}
// on success.
func runNewsPublish(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("news-publish", flag.ExitOnError)
	host := fs.String("host", "", "tracked SSH host name (Netbird → SSH)")
	dir := fs.String("dir", "", "remote directory to publish news.json + manifest.json into")
	_ = fs.Bool("json", false, "machine-readable output (always on for this command)")
	_ = fs.Parse(args)
	if *host == "" {
		return errors.New("--host is required")
	}
	if *dir == "" {
		return errors.New("--dir is required")
	}
	if err := svc.NewsPublisher.Publish(ctx, *host, *dir); err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]bool{"ok": true})
}

// runNewsPull pulls, verifies, and caches the Master's published snapshot
// from a shared SSH relay host — a Client machine calls this instead of
// `news fetch` (no local AI/aggregation on Client). Returns the cached
// NewsFeed (role "client") on success; the local cache is left untouched on
// any verification failure (hash mismatch or rollback).
func runNewsPull(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("news-pull", flag.ExitOnError)
	host := fs.String("host", "", "tracked SSH host name (Netbird → SSH)")
	dir := fs.String("dir", "", "remote directory news.json + manifest.json were published into")
	_ = fs.Bool("json", false, "machine-readable output (always on for this command)")
	_ = fs.Parse(args)
	if *host == "" {
		return errors.New("--host is required")
	}
	if *dir == "" {
		return errors.New("--dir is required")
	}
	feed, err := svc.NewsPuller.Pull(ctx, *host, *dir)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(&feed)
}
