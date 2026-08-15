// Package newsfetch fetches raw news/repo data for the news-dashboard
// aggregator: RSS/Atom feeds, GitHub repo search, and best-effort article
// image resolution. No AI/translation here — that's usecase/news +
// adapter/ollama|anthropic.
package newsfetch

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"html"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/mmcdole/gofeed"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

const (
	feedFetchTimeout = 15 * time.Second
	maxItemsPerFeed   = 20
	feedUserAgent     = "claude-bar-news/1.0 (+https://github.com/ncthanhngo/claude-bar)"
	maxDescriptionLen = 600
)

var htmlTagRe = regexp.MustCompile(`<[^>]+>`)

// RSS fetches and normalises one RSS/Atom feed at a time into port.NewsItem
// shapes. Stateless — safe for concurrent use across feeds.
type RSS struct {
	hc     *http.Client
	parser *gofeed.Parser
}

// NewRSS returns a ready-to-use RSS fetcher.
func NewRSS() *RSS {
	return &RSS{hc: &http.Client{}, parser: gofeed.NewParser()}
}

// FetchFeed downloads and parses feed.URL, returning up to maxItemsPerFeed
// normalised items. Category/TitleVI/SummaryVI/FullVI are left for the
// usecase layer to fill in (classification + AI summarisation).
func (r *RSS) FetchFeed(ctx context.Context, feed port.Feed) ([]port.NewsItem, error) {
	fetchCtx, cancel := context.WithTimeout(ctx, feedFetchTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(fetchCtx, http.MethodGet, feed.URL, nil)
	if err != nil {
		return nil, fmt.Errorf("build request for %s: %w", feed.URL, err)
	}
	req.Header.Set("User-Agent", feedUserAgent)

	resp, err := r.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetch feed %s: %w", feed.URL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("fetch feed %s: status %d", feed.URL, resp.StatusCode)
	}

	parsed, err := r.parser.Parse(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("parse feed %s: %w", feed.URL, err)
	}
	return normalizeFeedItems(parsed, feed), nil
}

// normalizeFeedItems maps parsed gofeed items into port.NewsItem shapes.
// Split out from FetchFeed so parsing correctness can be unit-tested
// against a captured fixture string without a network round-trip.
func normalizeFeedItems(parsed *gofeed.Feed, feed port.Feed) []port.NewsItem {
	if parsed == nil {
		return nil
	}
	label := feed.Label
	if label == "" {
		label = parsed.Title
	}

	items := make([]port.NewsItem, 0, len(parsed.Items))
	for i, it := range parsed.Items {
		if i >= maxItemsPerFeed {
			break
		}
		if it == nil || it.Link == "" {
			continue
		}
		items = append(items, port.NewsItem{
			ID:               stableID(it.Link),
			Title:            strings.TrimSpace(it.Title),
			Description:      itemDescription(it),
			SourceLabel:      label,
			SourceFaviconURL: faviconURL(it.Link),
			ImageURL:         sanitizeImageURL(extractItemImage(it)),
			OriginalURL:      it.Link,
			PublishedAt:      publishedAt(it),
		})
	}
	return items
}

// stableID hashes originalURL into a short stable ID — used for both
// NewsItem.ID and dedup across feeds/refreshes (contract: "id stable
// across refreshes (hash of originalURL)").
func stableID(originalURL string) string {
	sum := sha256.Sum256([]byte(originalURL))
	return hex.EncodeToString(sum[:8])
}

// itemDescription strips HTML tags/entities from the feed's description (or
// content, if description is empty) and caps its length — this raw English
// text is the AI summariser's input, never part of the JSON wire contract.
func itemDescription(it *gofeed.Item) string {
	raw := it.Description
	if raw == "" {
		raw = it.Content
	}
	text := htmlTagRe.ReplaceAllString(raw, " ")
	text = html.UnescapeString(text)
	text = strings.Join(strings.Fields(text), " ")
	return truncateRunes(text, maxDescriptionLen)
}

func truncateRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

// publishedAt formats the item's publish time as RFC3339 UTC, falling back
// to the updated time, or "" if the feed carries neither.
func publishedAt(it *gofeed.Item) string {
	if it.PublishedParsed != nil {
		return it.PublishedParsed.UTC().Format(time.RFC3339)
	}
	if it.UpdatedParsed != nil {
		return it.UpdatedParsed.UTC().Format(time.RFC3339)
	}
	return ""
}

// faviconURL builds a Google favicon-service URL from the article's host,
// matching the contract's sourceFaviconURL example exactly.
func faviconURL(pageURL string) string {
	u, err := url.Parse(pageURL)
	if err != nil || u.Host == "" {
		return ""
	}
	host := strings.TrimPrefix(u.Host, "www.")
	return "https://www.google.com/s2/favicons?domain=" + host + "&sz=64"
}

// extractItemImage looks for a feed-provided image: gofeed's universal
// Image field (populated from itunes:image / media:content in many feeds),
// then the first image/* enclosure. Anything else (arbitrary media:*
// extensions) is left to the image.go og:image fallback.
func extractItemImage(it *gofeed.Item) string {
	if it.Image != nil && it.Image.URL != "" {
		return it.Image.URL
	}
	for _, enc := range it.Enclosures {
		if enc != nil && strings.HasPrefix(enc.Type, "image/") && enc.URL != "" {
			return enc.URL
		}
	}
	return ""
}
