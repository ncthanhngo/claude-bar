package newsfetch

import (
	"context"
	"html"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sync"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

const (
	// imageFetchTimeout bounds one article-page fetch; a hung page must not
	// stall the whole aggregation run.
	imageFetchTimeout = 6 * time.Second
	// imageConcurrency caps how many article pages are fetched in parallel
	// when scraping og:image — bounded so a batch of slow/unreachable sites
	// can't fan out unboundedly.
	imageConcurrency = 4
	// maxHTMLBytes caps how much of each page we read looking for the
	// og:image meta tag — it's almost always in <head>, so a full download
	// of a multi-MB page is wasted work.
	maxHTMLBytes = 300 * 1024
)

// ogImageRe matches <meta property="og:image" content="URL"> in either
// attribute order — pages vary in which comes first.
var (
	ogImagePropertyFirst = regexp.MustCompile(`(?i)<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']`)
	ogImageContentFirst  = regexp.MustCompile(`(?i)<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']`)
)

// Image resolves the best-effort article image for news items whose feed
// didn't already carry one, by scraping the page's og:image meta tag.
type Image struct {
	hc *http.Client
}

// NewImage returns a ready-to-use image resolver.
func NewImage() *Image {
	return &Image{hc: &http.Client{}}
}

// ResolveMissing fills ImageURL for items that don't already have one, by
// fetching each article page with bounded concurrency (imageConcurrency)
// and a per-item timeout (imageFetchTimeout) — a slow/unreachable page
// can't serialise or hang the whole batch. Mutates and returns items.
func (im *Image) ResolveMissing(ctx context.Context, items []port.NewsItem) []port.NewsItem {
	sem := make(chan struct{}, imageConcurrency)
	var wg sync.WaitGroup
	for i := range items {
		if items[i].ImageURL != "" || items[i].OriginalURL == "" {
			continue
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(idx int) {
			defer wg.Done()
			defer func() { <-sem }()
			items[idx].ImageURL = im.fetchOGImage(ctx, items[idx].OriginalURL)
		}(i)
	}
	wg.Wait()
	return items
}

func (im *Image) fetchOGImage(ctx context.Context, pageURL string) string {
	fetchCtx, cancel := context.WithTimeout(ctx, imageFetchTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(fetchCtx, http.MethodGet, pageURL, nil)
	if err != nil {
		return ""
	}
	resp, err := im.hc.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return ""
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxHTMLBytes))
	if err != nil {
		return ""
	}
	m := ogImagePropertyFirst.FindSubmatch(body)
	if m == nil {
		m = ogImageContentFirst.FindSubmatch(body)
	}
	if m == nil {
		return ""
	}
	return sanitizeImageURL(string(m[1]))
}

// sanitizeImageURL enforces the contract's "https only" rule and rejects
// anything that doesn't parse into an absolute URL.
func sanitizeImageURL(raw string) string {
	if raw == "" {
		return ""
	}
	u, err := url.Parse(html.UnescapeString(raw))
	if err != nil || u.Scheme != "https" || u.Host == "" {
		return ""
	}
	return u.String()
}
