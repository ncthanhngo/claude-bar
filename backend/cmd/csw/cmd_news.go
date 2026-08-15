package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/ollama"
	"github.com/soi/claude-swap-widget/backend/internal/port"
	"github.com/soi/claude-swap-widget/backend/internal/usecase"
	"github.com/soi/claude-swap-widget/backend/internal/usecase/news"
)

// runNews dispatches `csw news
// <show|fetch|config|providers|publish|pull|article|save|unsave|saved>`.
// Every subcommand always prints JSON (the --json flag is accepted for
// consistency with the rest of the CLI but the news surface has no
// human-readable mode — the widget is the only caller).
func runNews(ctx context.Context, svc *usecase.Service, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw news <show|fetch|config|providers|publish|pull|article|save|unsave|saved>")
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
	case "article":
		return runNewsArticle(ctx, svc, rest)
	case "save":
		return runNewsSave(ctx, svc, rest)
	case "unsave":
		return runNewsUnsave(ctx, svc, rest)
	case "saved":
		return runNewsSaved(ctx, svc, rest)
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

// runNewsFetch aggregates now (feeds + repos + AI), MERGES the freshly
// fetched items into the previously persisted snapshot (dedupe by
// originalURL, drop anything older than the rolling 30-day retention
// window), persists, and returns the merged NewsFeed. Repos are always
// replaced by the fresh fetch — a live trending view, no accumulation.
// --force is accepted for CLI-surface parity with the plan but is a no-op
// today — v1 has no aggregation cache to bypass; every fetch already
// aggregates fresh (article-level caching is a separate, unrelated cache —
// see `csw news article`).
func runNewsFetch(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("news-fetch", flag.ExitOnError)
	_ = fs.Bool("force", false, "ignored — fetch always aggregates fresh (no cache in v1)")
	_ = fs.Bool("json", false, "machine-readable output (always on for this command)")
	_ = fs.Parse(args)

	cfg, err := svc.NewsStore.LoadConfig(ctx)
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	fresh, err := svc.NewsAggregator.Fetch(ctx, *cfg)
	if err != nil {
		return fmt.Errorf("fetch: %w", err)
	}

	prev, err := svc.NewsStore.LoadFeed(ctx)
	if err != nil {
		return fmt.Errorf("load previous snapshot: %w", err)
	}
	firstSeen, err := svc.NewsStore.LoadRetention(ctx)
	if err != nil {
		return fmt.Errorf("load retention state: %w", err)
	}

	merged, nextFirstSeen := news.MergeRetain(prev.Items, fresh.Items, firstSeen, time.Now().UTC())
	fresh.Items = merged

	if err := svc.NewsStore.SaveFeed(ctx, fresh); err != nil {
		return fmt.Errorf("persist: %w", err)
	}
	if err := svc.NewsStore.SaveRetention(ctx, nextFirstSeen); err != nil {
		return fmt.Errorf("persist retention state: %w", err)
	}
	return json.NewEncoder(os.Stdout).Encode(fresh)
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

// runNewsArticle fetches (or serves from cache) a full-article Vietnamese
// translation for one URL. Always exits 0 with ok:false + error on a
// fetch/translate failure — the CLI's error path is reserved for usage
// mistakes (missing --url), not remote-page failures the widget needs to
// display inline.
func runNewsArticle(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("news-article", flag.ExitOnError)
	url := fs.String("url", "", "article URL to fetch + translate")
	force := fs.Bool("force", false, "bypass the cache and re-fetch/translate")
	_ = fs.Bool("json", false, "machine-readable output (always on for this command)")
	_ = fs.Parse(args)
	if *url == "" {
		return errors.New("--url is required")
	}

	cfg, err := svc.NewsStore.LoadConfig(ctx)
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	article, err := svc.NewsArticles.Get(ctx, *url, *force, *cfg)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(article)
}

// runNewsSave reads a NewsItem or Repo JSON body on stdin (per --kind) and
// upserts it into the permanent bookmark store — idempotent by ID.
func runNewsSave(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("news-save", flag.ExitOnError)
	kind := fs.String("kind", "", `"item" or "repo"`)
	_ = fs.Bool("json", false, "machine-readable output (always on for this command)")
	_ = fs.Parse(args)

	body, err := io.ReadAll(os.Stdin)
	if err != nil {
		return fmt.Errorf("read stdin: %w", err)
	}
	switch *kind {
	case "item":
		var item port.NewsItem
		if err := json.Unmarshal(body, &item); err != nil {
			return fmt.Errorf("parse item JSON: %w", err)
		}
		if item.ID == "" {
			return errors.New("item.id is required")
		}
		if err := svc.NewsStore.SaveSavedItem(ctx, item); err != nil {
			return err
		}
	case "repo":
		var repo port.Repo
		if err := json.Unmarshal(body, &repo); err != nil {
			return fmt.Errorf("parse repo JSON: %w", err)
		}
		if repo.ID == "" {
			return errors.New("repo.id is required")
		}
		if err := svc.NewsStore.SaveSavedRepo(ctx, repo); err != nil {
			return err
		}
	default:
		return fmt.Errorf(`--kind must be "item" or "repo", got %q`, *kind)
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]bool{"ok": true})
}

// runNewsUnsave removes one saved item/repo by ID — idempotent (no error if
// already absent).
func runNewsUnsave(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("news-unsave", flag.ExitOnError)
	kind := fs.String("kind", "", `"item" or "repo"`)
	id := fs.String("id", "", "id of the saved item/repo to remove")
	_ = fs.Bool("json", false, "machine-readable output (always on for this command)")
	_ = fs.Parse(args)
	if *id == "" {
		return errors.New("--id is required")
	}

	switch *kind {
	case "item":
		if err := svc.NewsStore.RemoveSavedItem(ctx, *id); err != nil {
			return err
		}
	case "repo":
		if err := svc.NewsStore.RemoveSavedRepo(ctx, *id); err != nil {
			return err
		}
	default:
		return fmt.Errorf(`--kind must be "item" or "repo", got %q`, *kind)
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]bool{"ok": true})
}

// runNewsSaved returns the full permanent bookmark set.
func runNewsSaved(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("news-saved", flag.ExitOnError)
	_ = fs.Bool("json", false, "machine-readable output (always on for this command)")
	_ = fs.Parse(args)

	saved, err := svc.NewsStore.LoadSaved(ctx)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(saved)
}
