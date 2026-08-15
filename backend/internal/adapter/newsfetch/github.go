package newsfetch

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

const (
	githubSearchEndpoint = "https://api.github.com/search/repositories"
	githubTimeout        = 10 * time.Second
	// reposPerQuery is intentionally small: unauthenticated GitHub search is
	// rate-limited to 60 requests/hour, and the widget only needs a
	// handful of top repos per configured query, not a full page.
	reposPerQuery = 5
)

// GitHub searches repositories via the unauthenticated GitHub search API.
type GitHub struct {
	hc        *http.Client
	userAgent string
}

// NewGitHub returns a ready-to-use GitHub repo searcher.
func NewGitHub() *GitHub {
	return &GitHub{
		hc:        &http.Client{Timeout: githubTimeout},
		userAgent: "claude-bar-news/1.0 (+https://github.com/ncthanhngo/claude-bar)",
	}
}

type githubSearchResponse struct {
	Items []struct {
		FullName        string `json:"full_name"`
		HTMLURL         string `json:"html_url"`
		Description     string `json:"description"`
		Language        string `json:"language"`
		StargazersCount int    `json:"stargazers_count"`
	} `json:"items"`
}

// SearchRepos runs one topic/language query against GET
// /search/repositories?q=…&sort=stars, unauthenticated, and maps results to
// port.Repo. DeltaWeek stays 0 in v1 — the search API doesn't expose star
// history, and tracking it would need a persisted time series (YAGNI here).
func (g *GitHub) SearchRepos(ctx context.Context, q port.GitHubQuery) ([]port.Repo, error) {
	query := buildGitHubQuery(q, time.Now())
	if query == "" {
		return nil, errors.New("github: empty query (topic and language both blank)")
	}

	endpoint := fmt.Sprintf("%s?q=%s&sort=stars&order=desc&per_page=%d",
		githubSearchEndpoint, url.QueryEscape(query), reposPerQuery)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("github: build request: %w", err)
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", g.userAgent)

	resp, err := g.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("github search: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusForbidden {
		return nil, errors.New("github search: rate limited (unauthenticated, 60/hour)")
	}
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("github search: status %d", resp.StatusCode)
	}

	var body githubSearchResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, fmt.Errorf("github search: decode: %w", err)
	}

	out := make([]port.Repo, 0, len(body.Items))
	for _, it := range body.Items {
		if it.FullName == "" || it.HTMLURL == "" {
			continue
		}
		out = append(out, port.Repo{
			ID:          it.FullName,
			FullName:    it.FullName,
			Language:    it.Language,
			LangColor:   languageColor(it.Language),
			Stars:       it.StargazersCount,
			URL:         it.HTMLURL,
			Category:    port.CategoryGitHub,
			Description: it.Description,
		})
	}
	return out, nil
}

// pushedWithin bounds SearchRepos to repos pushed in roughly the last 18
// months. A pure `sort=stars` over GitHub's full history surfaces whatever
// mega-starred repo happens to carry the queried topic tag among dozens of
// others (implausible/irrelevant top hits for a narrow topic like "llm" or
// "iot") — requiring recent activity is a cheap quality signal that keeps
// results to repos still actually relevant to what's being searched for.
const pushedWithin = -18 // months

// buildGitHubQuery renders the `q=` search string: topic:<x> and/or
// language:<y>, plus a `pushed:>` recency/quality bound, space-joined
// (GitHub search treats a space as logical AND). Returns "" when neither
// topic nor language is set — SearchRepos treats that as a config error
// rather than running an unbounded query.
func buildGitHubQuery(q port.GitHubQuery, now time.Time) string {
	var parts []string
	if q.Topic != "" {
		parts = append(parts, "topic:"+q.Topic)
	}
	if q.Language != "" {
		parts = append(parts, "language:"+q.Language)
	}
	if len(parts) == 0 {
		return ""
	}
	parts = append(parts, "pushed:>"+now.AddDate(0, pushedWithin, 0).Format("2006-01-02"))
	return strings.Join(parts, " ")
}

// languageColors mirrors GitHub's linguist colours for the languages the
// seed queries actually surface; languageColor falls back to GitHub's own
// "unknown language" grey for anything not in this small curated set.
var languageColors = map[string]string{
	"Go":         "#00add8",
	"Python":     "#3572a5",
	"JavaScript": "#f1e05a",
	"TypeScript": "#3178c6",
	"Rust":       "#dea584",
	"C++":        "#f34b7d",
	"C":          "#555555",
	"Java":       "#b07219",
	"Swift":      "#f05138",
	"Ruby":       "#701516",
	"Shell":      "#89e051",
	"HTML":       "#e34c26",
	"CSS":        "#563d7c",
	"C#":         "#178600",
	"Kotlin":     "#a97bff",
	"PHP":        "#4f5d95",
	"Dart":       "#00b4ab",
}

func languageColor(lang string) string {
	if c, ok := languageColors[lang]; ok {
		return c
	}
	return "#8b949e"
}
