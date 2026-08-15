package news

import (
	"context"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

const (
	// summarizeConcurrency bounds how many Summarize calls (news items +
	// repo descriptions combined) run at once. Local Ollama models are
	// single-threaded-ish on modest hardware, so a small pool overlaps
	// network/HTTP latency without saturating the machine.
	summarizeConcurrency = 3
	// summarizeItemTimeout bounds one item's Summarize call independent of
	// the adapter's own internal timeout — caps how long one stuck call can
	// hold a worker slot before the aggregation moves on.
	summarizeItemTimeout = 90 * time.Second
)

// FeedFetcher fetches and normalises items from one RSS/Atom feed.
// Implementation: adapter/newsfetch.RSS.
type FeedFetcher interface {
	FetchFeed(ctx context.Context, feed port.Feed) ([]port.NewsItem, error)
}

// RepoFetcher searches GitHub repositories matching one query.
// Implementation: adapter/newsfetch.GitHub.
type RepoFetcher interface {
	SearchRepos(ctx context.Context, q port.GitHubQuery) ([]port.Repo, error)
}

// ImageResolver best-effort fills ImageURL for items that don't already
// have one. Implementation: adapter/newsfetch.Image.
type ImageResolver interface {
	ResolveMissing(ctx context.Context, items []port.NewsItem) []port.NewsItem
}

// Aggregator implements port.NewsAggregator: fetch feeds+repos, translate/
// summarise each to Vietnamese via the provider router, assemble one
// NewsFeed. Role is fixed to "master" — client-side pull is Phase 4.
type Aggregator struct {
	Feeds  FeedFetcher
	Repos  RepoFetcher
	Images ImageResolver
	Router *ProviderRouter
	Now    func() time.Time
}

// NewAggregator wires the four collaborators, defaulting Now to time.Now.
func NewAggregator(feeds FeedFetcher, repos RepoFetcher, images ImageResolver, router *ProviderRouter) *Aggregator {
	return &Aggregator{
		Feeds:  feeds,
		Repos:  repos,
		Images: images,
		Router: router,
		Now:    func() time.Time { return time.Now().UTC() },
	}
}

// Fetch assembles one NewsFeed snapshot. Best-effort throughout: a single
// feed/repo-query failure is recorded in SourcesHealth and does not abort
// the rest of the run — partial news beats no news. Likewise a single
// item's summarisation failure leaves its Vietnamese fields empty rather
// than dropping the (still useful, English) item.
func (a *Aggregator) Fetch(ctx context.Context, cfg port.NewsConfig) (*port.NewsFeed, error) {
	health := map[string]string{}
	items := a.fetchItems(ctx, cfg.Feeds, health)
	repos := a.fetchRepos(ctx, cfg.GithubQueries, health)

	if a.Images != nil && len(items) > 0 {
		items = a.Images.ResolveMissing(ctx, items)
	}

	// Track which provider actually summarised each item so the snapshot can
	// report the one that did the bulk of the work — not just whichever
	// goroutine happened to finish last (which, with a Claude fallback on a
	// few timed-out items, could misreport a mostly-Ollama run as "claude").
	providerCounts := map[string]int{}
	var providerMu sync.Mutex
	sem := make(chan struct{}, summarizeConcurrency)
	var wg sync.WaitGroup

	for i := range items {
		items[i].Category = classify(items[i].Title + " " + items[i].Description)
		if items[i].Title == "" {
			continue
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(i int) {
			defer wg.Done()
			defer func() { <-sem }()
			itemCtx, cancel := context.WithTimeout(ctx, summarizeItemTimeout)
			defer cancel()
			result, err := a.Router.Summarize(itemCtx, port.SummarizeInput{
				Title:       items[i].Title,
				Description: items[i].Description,
				URL:         items[i].OriginalURL,
			}, cfg)
			if err != nil {
				return
			}
			items[i].TitleVI = result.TitleVI
			items[i].SummaryVI = result.SummaryVI
			items[i].FullVI = result.FullVI
			providerMu.Lock()
			providerCounts[result.Provider]++
			providerMu.Unlock()
		}(i)
	}
	wg.Wait()

	// Repo descriptions get the same bounded-concurrency, per-item-timeout
	// treatment. A repo with no upstream English description has nothing to
	// translate, so descVI stays "" rather than spending a call asking the
	// model to invent one.
	for i := range repos {
		if repos[i].FullName == "" || repos[i].Description == "" {
			continue
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(i int) {
			defer wg.Done()
			defer func() { <-sem }()
			repoCtx, cancel := context.WithTimeout(ctx, summarizeItemTimeout)
			defer cancel()
			result, err := a.Router.Summarize(repoCtx, port.SummarizeInput{
				Title:       repos[i].FullName,
				Description: repos[i].Description,
				URL:         repos[i].URL,
			}, cfg)
			if err != nil {
				return
			}
			repos[i].DescVI = result.SummaryVI
			providerMu.Lock()
			providerCounts[result.Provider]++
			providerMu.Unlock()
		}(i)
	}
	wg.Wait()

	items = dedupeItems(items)
	sort.Slice(items, func(i, j int) bool { return items[i].PublishedAt > items[j].PublishedAt })
	sort.Slice(repos, func(i, j int) bool { return repos[i].Stars > repos[j].Stars })
	if repos == nil {
		repos = []port.Repo{}
	}

	providerUsed := majorityProvider(providerCounts, cfg.Provider)
	model := a.Router.ResolveModel(ctx, providerUsed, cfg)

	return &port.NewsFeed{
		SchemaVersion: 1,
		GeneratedAt:   a.Now().Format(time.RFC3339),
		Role:          "master",
		Provider:      providerUsed,
		Model:         model,
		Items:         items,
		Repos:         repos,
		SourcesHealth: health,
	}, nil
}

// majorityProvider returns the provider that summarised the most items. Ties
// and an all-failed run fall back to the configured provider (then "ollama"),
// so the snapshot always names a real provider.
func majorityProvider(counts map[string]int, configured string) string {
	best, bestN := "", -1
	for p, n := range counts {
		if n > bestN {
			best, bestN = p, n
		}
	}
	if best != "" {
		return best
	}
	if configured != "" {
		return configured
	}
	return "ollama"
}

// fetchItems pulls items from every enabled RSS-mode feed, recording each
// feed's outcome ("ok"/"error") into health. A feed configured with the
// not-yet-implemented aiSummary mode is recorded as "chưa hỗ trợ" rather than
// dropped silently, so the UI shows the source was skipped.
func (a *Aggregator) fetchItems(ctx context.Context, feeds []port.Feed, health map[string]string) []port.NewsItem {
	var all []port.NewsItem
	for _, f := range feeds {
		if !f.Enabled {
			continue
		}
		label := f.Label
		if label == "" {
			label = f.URL
		}
		if f.Mode != port.FeedModeRSS {
			health[label] = "chưa hỗ trợ"
			continue
		}
		fetched, err := a.Feeds.FetchFeed(ctx, f)
		if err != nil {
			health[label] = "error"
			continue
		}
		health[label] = "ok"
		all = append(all, fetched...)
	}
	return all
}

// fetchRepos runs every configured GitHub query, deduping across queries by
// FullName, and records each query's outcome into health.
func (a *Aggregator) fetchRepos(ctx context.Context, queries []port.GitHubQuery, health map[string]string) []port.Repo {
	var all []port.Repo
	seen := map[string]bool{}
	for _, q := range queries {
		label := "GitHub: " + strings.TrimSpace(q.Topic+" "+q.Language)
		fetched, err := a.Repos.SearchRepos(ctx, q)
		if err != nil {
			health[label] = "error"
			continue
		}
		health[label] = "ok"
		for _, r := range fetched {
			if seen[r.FullName] {
				continue
			}
			seen[r.FullName] = true
			all = append(all, r)
		}
	}
	return all
}

// dedupeItems drops items sharing an OriginalURL — the contract's dedupe
// rule, needed because the same article can appear in multiple feeds.
func dedupeItems(items []port.NewsItem) []port.NewsItem {
	seen := map[string]bool{}
	out := make([]port.NewsItem, 0, len(items))
	for _, it := range items {
		if it.OriginalURL == "" || seen[it.OriginalURL] {
			continue
		}
		seen[it.OriginalURL] = true
		out = append(out, it)
	}
	return out
}

// classify assigns a best-effort category from keyword heuristics on the
// item's title+description. Defaults to "other" — an unclassified item is
// not necessarily a dev-focused one, and "other" keeps the category spread
// honest rather than lumping everything unmatched into "dev".
func classify(text string) string {
	t := strings.ToLower(text)
	switch {
	case containsAny(t, "openai", "anthropic", "claude", "gpt", "llm", "machine learning", "artificial intelligence",
		" ai ", "chatbot", "neural network", "deep learning", "gemini", "copilot", "stable diffusion",
		"midjourney", "hugging face", "transformer model", "generative ai", "large language model"):
		return port.CategoryAI
	case containsAny(t, "iot", "raspberry pi", "arduino", "embedded", "microcontroller", "esp32", "smart home",
		" sensor", "firmware", "3d print", "robotics", "fpga", "home assistant", "zigbee"):
		return port.CategoryIoT
	case containsAny(t, "programming", "developer", "framework", "open source", "github", "compiler", "database",
		" api ", "kubernetes", "docker", "golang", " go ", " rust ", "javascript", "typescript", "python",
		"software engineering", "code review", "debugging", "devops", " cli ", " sdk ", "library", "linux", "terminal"):
		return port.CategoryDev
	default:
		return port.CategoryOther
	}
}

func containsAny(s string, subs ...string) bool {
	for _, sub := range subs {
		if strings.Contains(s, sub) {
			return true
		}
	}
	return false
}

// Compile-time guard: Aggregator implements the port.
var _ port.NewsAggregator = (*Aggregator)(nil)
