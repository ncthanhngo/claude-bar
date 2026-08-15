package port

import "context"

// FeedMode discriminates how a configured feed is consumed. "rss" is a
// plain RSS/Atom feed; "aiSummary" mirrors the Swift NewsFeedConfig.Mode
// enum for a future mode where the source itself needs AI-only extraction
// (no RSS available) — not implemented by the aggregator in v1, but kept in
// the schema so Settings can offer the toggle without another round-trip.
type FeedMode string

const (
	FeedModeRSS       FeedMode = "rss"
	FeedModeAISummary FeedMode = "aiSummary"
)

// News item categories. "other" is the catch-all the classifier falls back
// to when nothing else matches; "github" is reserved for Repo entries.
const (
	CategoryAI     = "ai"
	CategoryDev    = "dev"
	CategoryGitHub = "github"
	CategoryIoT    = "iot"
	CategoryOther  = "other"
)

// Feed is one configured RSS/Atom source. JSON tags match the shared
// contract exactly — Swift decodes this struct byte-for-byte.
type Feed struct {
	ID      string   `json:"id"`
	URL     string   `json:"url"`
	Label   string   `json:"label"`
	Mode    FeedMode `json:"mode"`
	Enabled bool     `json:"enabled"`
}

// GitHubQuery is one GitHub repo-search filter: topic and/or language.
// At least one of the two must be non-empty for the adapter to run it.
type GitHubQuery struct {
	Topic    string `json:"topic"`
	Language string `json:"language"`
}

// NewsItem is one aggregated news article, English + Vietnamese fields
// side by side. Description is the raw English snippet used only to build
// the AI summarise/translate prompt — it is never part of the wire
// contract (json:"-"), so it's dropped automatically on marshal.
type NewsItem struct {
	ID               string `json:"id"`
	Category         string `json:"category"`
	Title            string `json:"title"`
	TitleVI          string `json:"titleVI"`
	SourceLabel      string `json:"sourceLabel"`
	SourceFaviconURL string `json:"sourceFaviconURL"`
	ImageURL         string `json:"imageURL"`
	SummaryVI        string `json:"summaryVI"`
	FullVI           string `json:"fullVI"`
	OriginalURL      string `json:"originalURL"`
	PublishedAt      string `json:"publishedAt"`

	Description string `json:"-"`
}

// Repo is one aggregated GitHub repository. Description mirrors NewsItem's
// pattern — the raw English repo description feeds the AI translator that
// fills DescVI, and is never serialised.
type Repo struct {
	ID        string `json:"id"`
	FullName  string `json:"fullName"`
	DescVI    string `json:"descVI"`
	Language  string `json:"language"`
	LangColor string `json:"langColor"`
	Stars     int    `json:"stars"`
	DeltaWeek int    `json:"deltaWeek"`
	URL       string `json:"url"`
	Category  string `json:"category"`

	Description string `json:"-"`
}

// NewsFeed is the full payload of `csw news show|fetch`. Items/Repos/
// SourcesHealth must always serialise as [] / {} — never null — per the
// nil-slice pitfall (Swift's non-optional array decode fails on null).
type NewsFeed struct {
	SchemaVersion int               `json:"schemaVersion"`
	GeneratedAt   string            `json:"generatedAt"`
	Role          string            `json:"role"`
	Provider      string            `json:"provider"`
	Model         string            `json:"model"`
	Items         []NewsItem        `json:"items"`
	Repos         []Repo            `json:"repos"`
	SourcesHealth map[string]string `json:"sourcesHealth"`
}

// NewsConfig is the payload of `csw news config get|set`. Go owns this file
// as the authority for aggregation settings; Swift's @AppStorage owns the
// separate per-machine role/relay/cadence settings (not part of this type).
type NewsConfig struct {
	SchemaVersion         int           `json:"schemaVersion"`
	Provider              string        `json:"provider"`
	OllamaModel           string        `json:"ollamaModel"`
	ClaudeFallbackEnabled bool          `json:"claudeFallbackEnabled"`
	Feeds                 []Feed        `json:"feeds"`
	GithubQueries         []GitHubQuery `json:"githubQueries"`
}

// NewsAggregator fetches feeds + GitHub repos, summarises/translates each
// item to Vietnamese via the configured provider, and returns one NewsFeed
// snapshot. Implementations: usecase/news.Aggregator.
type NewsAggregator interface {
	Fetch(ctx context.Context, cfg NewsConfig) (*NewsFeed, error)
}

// NewsStore persists/reads the last NewsFeed snapshot and the NewsConfig,
// atomically (temp file → fsync → rename). Implementations:
// adapter/newsstore.Store.
type NewsStore interface {
	LoadFeed(ctx context.Context) (*NewsFeed, error)
	SaveFeed(ctx context.Context, feed *NewsFeed) error
	LoadConfig(ctx context.Context) (*NewsConfig, error)
	SaveConfig(ctx context.Context, cfg *NewsConfig) error
}
