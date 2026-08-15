// Package newsstore persists the news-dashboard snapshot and its config
// under ~/Library/Application Support/claude-swap-widget/news/. Every write
// goes temp-file → fsync → rename so a crash mid-write never corrupts the
// file a concurrent reader (`csw news show`) might be reading.
package newsstore

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// Store implements port.NewsStore against two JSON files in dir.
type Store struct {
	dir string
}

// NewStore returns a Store rooted at the production news data dir.
func NewStore() *Store {
	return NewStoreAt(filepath.Join(adapter.WidgetDataDir(), "news"))
}

// NewStoreAt returns a Store rooted at an arbitrary directory — used by
// tests to avoid touching the real Application Support dir.
func NewStoreAt(dir string) *Store {
	return &Store{dir: dir}
}

func (s *Store) feedFile() string   { return filepath.Join(s.dir, "news.json") }
func (s *Store) configFile() string { return filepath.Join(s.dir, "config.json") }

// LoadFeed returns the last persisted snapshot, or an empty-but-valid
// NewsFeed (items/repos as [], never null) if nothing has been fetched yet.
func (s *Store) LoadFeed(_ context.Context) (*port.NewsFeed, error) {
	var feed port.NewsFeed
	ok, err := readJSON(s.feedFile(), &feed)
	if err != nil {
		return nil, err
	}
	if !ok {
		feed = port.NewsFeed{SchemaVersion: 1, Role: "master"}
	}
	normalizeFeed(&feed)
	return &feed, nil
}

// SaveFeed atomically persists feed, normalising nil slices/maps to their
// empty JSON forms first.
func (s *Store) SaveFeed(_ context.Context, feed *port.NewsFeed) error {
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return fmt.Errorf("news store: mkdir: %w", err)
	}
	normalizeFeed(feed)
	return writeJSONAtomic(s.feedFile(), feed)
}

// LoadConfig returns the persisted config, seeding + persisting sensible
// defaults on first call so `csw news config get` never errors just
// because the app hasn't been configured yet.
func (s *Store) LoadConfig(ctx context.Context) (*port.NewsConfig, error) {
	var cfg port.NewsConfig
	ok, err := readJSON(s.configFile(), &cfg)
	if err != nil {
		return nil, err
	}
	if !ok {
		cfg = defaultConfig()
		if err := s.SaveConfig(ctx, &cfg); err != nil {
			return nil, fmt.Errorf("news store: seed default config: %w", err)
		}
	}
	normalizeConfig(&cfg)
	return &cfg, nil
}

// SaveConfig atomically persists cfg — Go's config.json is the aggregation
// authority; the widget always round-trips a full object here.
func (s *Store) SaveConfig(_ context.Context, cfg *port.NewsConfig) error {
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return fmt.Errorf("news store: mkdir: %w", err)
	}
	normalizeConfig(cfg)
	return writeJSONAtomic(s.configFile(), cfg)
}

// normalizeFeed guarantees Items/Repos/SourcesHealth serialise as [] / {}
// — never null — so the Swift decoder never trips the nil-slice pitfall.
func normalizeFeed(f *port.NewsFeed) {
	if f.Items == nil {
		f.Items = []port.NewsItem{}
	}
	if f.Repos == nil {
		f.Repos = []port.Repo{}
	}
	if f.SourcesHealth == nil {
		f.SourcesHealth = map[string]string{}
	}
	if f.SchemaVersion == 0 {
		f.SchemaVersion = 1
	}
	if f.Role == "" {
		f.Role = "master"
	}
}

func normalizeConfig(c *port.NewsConfig) {
	if c.Feeds == nil {
		c.Feeds = []port.Feed{}
	}
	if c.GithubQueries == nil {
		c.GithubQueries = []port.GitHubQuery{}
	}
	if c.SchemaVersion == 0 {
		c.SchemaVersion = 1
	}
}

// readJSON decodes path into v; returns ok=false (no error) when the file
// doesn't exist yet — the normal "nothing fetched/configured yet" state.
func readJSON(path string, v any) (bool, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("news store: read %s: %w", path, err)
	}
	if err := json.Unmarshal(b, v); err != nil {
		return false, fmt.Errorf("news store: parse %s: %w", path, err)
	}
	return true, nil
}

// writeJSONAtomic writes v to path via temp-file → fsync → rename so a
// concurrent reader never observes a partially-written file, and a crash
// mid-write leaves the previous good copy in place.
func writeJSONAtomic(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return fmt.Errorf("news store: marshal: %w", err)
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".news-*.tmp")
	if err != nil {
		return fmt.Errorf("news store: create temp: %w", err)
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath) // no-op once renamed away

	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return fmt.Errorf("news store: write temp: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("news store: fsync temp: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("news store: close temp: %w", err)
	}
	if err := os.Chmod(tmpPath, 0o600); err != nil {
		return fmt.Errorf("news store: chmod temp: %w", err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return fmt.Errorf("news store: rename: %w", err)
	}
	return nil
}

// defaultConfig seeds sensible aggregation defaults so `csw news config
// get` and a first `csw news fetch` both work out of the box: Hacker News
// plus two well-known dev/AI blogs, and the three GitHub queries the plan
// calls for (language:Go, topic:llm, topic:iot).
func defaultConfig() port.NewsConfig {
	return port.NewsConfig{
		SchemaVersion:         1,
		Provider:              "ollama",
		OllamaModel:           "",
		ClaudeFallbackEnabled: false,
		Feeds: []port.Feed{
			{ID: newFeedID(), URL: "https://news.ycombinator.com/rss", Label: "Hacker News", Mode: port.FeedModeRSS, Enabled: true},
			{ID: newFeedID(), URL: "https://simonwillison.net/atom/everything/", Label: "Simon Willison", Mode: port.FeedModeRSS, Enabled: true},
			{ID: newFeedID(), URL: "https://feeds.arstechnica.com/arstechnica/index", Label: "Ars Technica", Mode: port.FeedModeRSS, Enabled: true},
		},
		GithubQueries: []port.GitHubQuery{
			{Language: "Go"},
			{Topic: "llm"},
			{Topic: "iot"},
		},
	}
}

// newFeedID returns an 8-byte hex string — plenty of collision resistance
// for a handful of seeded feed rows, no UUID dependency needed.
func newFeedID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// Compile-time guard.
var _ port.NewsStore = (*Store)(nil)
