package newsstore

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

func TestStore_SaveLoadFeedRoundTrip(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "news")
	s := NewStoreAt(dir)
	ctx := context.Background()

	feed := &port.NewsFeed{
		SchemaVersion: 1,
		Role:          "master",
		Provider:      "ollama",
		Items:         []port.NewsItem{{ID: "abc", Title: "Hello", OriginalURL: "https://example.com"}},
	}
	if err := s.SaveFeed(ctx, feed); err != nil {
		t.Fatalf("SaveFeed: %v", err)
	}

	loaded, err := s.LoadFeed(ctx)
	if err != nil {
		t.Fatalf("LoadFeed: %v", err)
	}
	if len(loaded.Items) != 1 || loaded.Items[0].ID != "abc" {
		t.Errorf("items = %+v", loaded.Items)
	}
	if loaded.Repos == nil {
		t.Error("Repos should never be nil after round-trip")
	}
}

func TestStore_LoadFeedEmptyStateHasNoNullSlices(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "news")
	s := NewStoreAt(dir)

	feed, err := s.LoadFeed(context.Background())
	if err != nil {
		t.Fatalf("LoadFeed: %v", err)
	}
	if feed.Items == nil || feed.Repos == nil {
		t.Errorf("expected empty slices, not nil: items=%v repos=%v", feed.Items, feed.Repos)
	}
	if feed.SourcesHealth == nil {
		t.Error("expected empty map, not nil")
	}
}

func TestStore_LoadConfigSeedsAndPersistsDefaults(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "news")
	s := NewStoreAt(dir)

	cfg, err := s.LoadConfig(context.Background())
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.Provider != "ollama" {
		t.Errorf("provider = %q, want ollama default", cfg.Provider)
	}
	if len(cfg.Feeds) == 0 {
		t.Error("expected seeded default feeds")
	}
	if len(cfg.GithubQueries) == 0 {
		t.Error("expected seeded default github queries")
	}

	// A second Store instance over the same dir must see the persisted
	// seed, not re-seed a different random set of feed IDs.
	s2 := NewStoreAt(dir)
	cfg2, err := s2.LoadConfig(context.Background())
	if err != nil {
		t.Fatalf("LoadConfig (2nd instance): %v", err)
	}
	if len(cfg2.Feeds) != len(cfg.Feeds) {
		t.Errorf("second load feed count = %d, want %d", len(cfg2.Feeds), len(cfg.Feeds))
	}
	if cfg2.Feeds[0].ID != cfg.Feeds[0].ID {
		t.Errorf("seed was not persisted: %q vs %q", cfg2.Feeds[0].ID, cfg.Feeds[0].ID)
	}
}

func TestStore_SaveConfigRoundTrip(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "news")
	s := NewStoreAt(dir)

	cfg := &port.NewsConfig{
		SchemaVersion:         1,
		Provider:              "claude",
		ClaudeFallbackEnabled: true,
		Feeds:                 []port.Feed{{ID: "1", URL: "https://a.com/rss", Label: "A", Mode: port.FeedModeRSS, Enabled: true}},
		GithubQueries:         []port.GitHubQuery{{Language: "Go"}},
	}
	if err := s.SaveConfig(context.Background(), cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	loaded, err := s.LoadConfig(context.Background())
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if loaded.Provider != "claude" || !loaded.ClaudeFallbackEnabled {
		t.Errorf("loaded = %+v", loaded)
	}
	if len(loaded.Feeds) != 1 || loaded.Feeds[0].Label != "A" {
		t.Errorf("feeds = %+v", loaded.Feeds)
	}
}
