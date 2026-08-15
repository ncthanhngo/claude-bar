package news

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// fakeFeedFetcher returns a canned set of items per feed URL, or an error
// for URLs listed in errURLs — enough to exercise SourcesHealth without any
// network I/O.
type fakeFeedFetcher struct {
	itemsByURL map[string][]port.NewsItem
	errURLs    map[string]bool
}

func (f *fakeFeedFetcher) FetchFeed(_ context.Context, feed port.Feed) ([]port.NewsItem, error) {
	if f.errURLs[feed.URL] {
		return nil, errors.New("boom")
	}
	return f.itemsByURL[feed.URL], nil
}

type fakeRepoFetcher struct {
	repos []port.Repo
}

func (f *fakeRepoFetcher) SearchRepos(_ context.Context, _ port.GitHubQuery) ([]port.Repo, error) {
	return f.repos, nil
}

// fakeImageResolver is a no-op stand-in — image resolution isn't under
// test here (covered separately in adapter/newsfetch).
type fakeImageResolver struct{}

func (fakeImageResolver) ResolveMissing(_ context.Context, items []port.NewsItem) []port.NewsItem {
	return items
}

func TestAggregator_DedupesAndNeverReturnsNilSlices(t *testing.T) {
	dupeURL := "https://example.com/dupe"
	feeds := &fakeFeedFetcher{
		itemsByURL: map[string][]port.NewsItem{
			"https://a.example/rss": {
				{Title: "A1", OriginalURL: dupeURL, PublishedAt: "2026-08-15T06:00:00Z"},
			},
			"https://b.example/rss": {
				{Title: "A1 duplicate", OriginalURL: dupeURL, PublishedAt: "2026-08-15T06:00:00Z"},
				{Title: "B1", OriginalURL: "https://example.com/b1", PublishedAt: "2026-08-14T06:00:00Z"},
			},
		},
		errURLs: map[string]bool{"https://c.example/rss": true},
	}
	router := NewProviderRouter(&fakeSummarizer{titleVI: "t", summaryVI: "s", fullVI: "f"}, nil)
	agg := NewAggregator(feeds, &fakeRepoFetcher{}, fakeImageResolver{}, router)
	agg.Now = func() time.Time { return time.Date(2026, 8, 15, 8, 0, 0, 0, time.UTC) }

	cfg := port.NewsConfig{
		Provider: "ollama",
		Feeds: []port.Feed{
			{URL: "https://a.example/rss", Label: "A", Mode: port.FeedModeRSS, Enabled: true},
			{URL: "https://b.example/rss", Label: "B", Mode: port.FeedModeRSS, Enabled: true},
			{URL: "https://c.example/rss", Label: "C", Mode: port.FeedModeRSS, Enabled: true},
			{URL: "https://d.example/rss", Label: "D", Mode: port.FeedModeRSS, Enabled: false},
		},
	}

	feed, err := agg.Fetch(context.Background(), cfg)
	if err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if len(feed.Items) != 2 {
		t.Fatalf("want 2 deduped items, got %d: %+v", len(feed.Items), feed.Items)
	}
	if feed.Items[0].OriginalURL != dupeURL {
		t.Errorf("expected newest item first, got %+v", feed.Items[0])
	}
	if feed.Items[0].TitleVI != "t" || feed.Items[0].SummaryVI != "s" || feed.Items[0].FullVI != "f" {
		t.Errorf("expected AI fields filled in, got %+v", feed.Items[0])
	}
	if feed.SourcesHealth["A"] != "ok" || feed.SourcesHealth["B"] != "ok" {
		t.Errorf("expected ok health for A/B, got %+v", feed.SourcesHealth)
	}
	if feed.SourcesHealth["C"] != "error" {
		t.Errorf("expected error health for C, got %+v", feed.SourcesHealth)
	}
	if _, disabledPresent := feed.SourcesHealth["D"]; disabledPresent {
		t.Errorf("disabled feed D should not be probed, health = %+v", feed.SourcesHealth)
	}
	if feed.Repos == nil {
		t.Error("Repos must never be nil")
	}
}

func TestAggregator_RepoDescVIFilledOnlyWhenDescriptionPresent(t *testing.T) {
	summarizer := &fakeSummarizer{summaryVI: "mô tả tiếng Việt", fullVI: "f"}
	router := NewProviderRouter(summarizer, nil)
	repos := &fakeRepoFetcher{repos: []port.Repo{
		{FullName: "a/has-desc", Description: "An actual description", URL: "https://github.com/a/has-desc"},
		{FullName: "b/no-desc", Description: "", URL: "https://github.com/b/no-desc"},
	}}
	agg := NewAggregator(&fakeFeedFetcher{}, repos, fakeImageResolver{}, router)

	cfg := port.NewsConfig{Provider: "ollama", GithubQueries: []port.GitHubQuery{{Language: "Go"}}}
	feed, err := agg.Fetch(context.Background(), cfg)
	if err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if len(feed.Repos) != 2 {
		t.Fatalf("want 2 repos, got %d: %+v", len(feed.Repos), feed.Repos)
	}
	byName := map[string]port.Repo{}
	for _, r := range feed.Repos {
		byName[r.FullName] = r
	}
	if byName["a/has-desc"].DescVI != "mô tả tiếng Việt" {
		t.Errorf("expected DescVI filled for a repo with an English description, got %+v", byName["a/has-desc"])
	}
	if byName["b/no-desc"].DescVI != "" {
		t.Errorf("expected DescVI to stay empty for a repo with no English description, got %+v", byName["b/no-desc"])
	}
	// Only the one repo with a description should have triggered a
	// Summarize call — the empty-description repo must be skipped entirely.
	if summarizer.calls != 1 {
		t.Errorf("summarizer.calls = %d, want 1 (only the repo with a description)", summarizer.calls)
	}
}

func TestAggregator_SetsModelFromRouter(t *testing.T) {
	router := NewProviderRouter(&fakeResolvingSummarizer{resolved: "qwen2.5:14b"}, nil)
	agg := NewAggregator(&fakeFeedFetcher{}, &fakeRepoFetcher{}, fakeImageResolver{}, router)

	feed, err := agg.Fetch(context.Background(), port.NewsConfig{Provider: "ollama"})
	if err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if feed.Model != "qwen2.5:14b" {
		t.Errorf("Model = %q, want the auto-resolved Ollama model", feed.Model)
	}
	if feed.Provider != "ollama" {
		t.Errorf("Provider = %q, want ollama", feed.Provider)
	}
}

func TestAggregator_EmptyConfigProducesEmptySlicesNotNil(t *testing.T) {
	router := NewProviderRouter(&fakeSummarizer{}, nil)
	agg := NewAggregator(&fakeFeedFetcher{}, &fakeRepoFetcher{}, fakeImageResolver{}, router)

	feed, err := agg.Fetch(context.Background(), port.NewsConfig{Provider: "ollama"})
	if err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if feed.Items == nil {
		t.Error("Items should be an empty slice, not nil")
	}
	if feed.Repos == nil {
		t.Error("Repos should be an empty slice, not nil")
	}
	if feed.Role != "master" {
		t.Errorf("Role = %q, want master", feed.Role)
	}
}

func TestClassify(t *testing.T) {
	cases := map[string]string{
		"OpenAI ships a new GPT model":       port.CategoryAI,
		"Raspberry Pi project for beginners": port.CategoryIoT,
		"A new Go concurrency pattern":       port.CategoryDev,
	}
	for text, want := range cases {
		if got := classify(text); got != want {
			t.Errorf("classify(%q) = %q, want %q", text, got, want)
		}
	}
}
