package newsfetch

import (
	"context"
	"fmt"
	"html"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
)

const (
	// articleFetchTimeout bounds one article-page fetch for the on-demand
	// full-text translation flow — generous relative to feedFetchTimeout
	// since this is a single user-triggered request, not a batch.
	articleFetchTimeout = 20 * time.Second
	// maxArticleHTMLBytes caps how much of the page is read — most articles
	// are well under this; it exists to bound a pathological/huge response.
	maxArticleHTMLBytes = 2 * 1024 * 1024
	// maxArticleTextChars caps the extracted body handed to the translator —
	// keeps the AI call's input (and local-model latency) bounded even for
	// very long articles.
	maxArticleTextChars = 8000
)

// Boilerplate is stripped in three separate passes (script/style first, then
// <head>, then nav/header/footer/form chrome) rather than one combined
// alternation — Go's RE2 engine has no backreferences, so a single
// `<(a|b)>.*?</(a|b)>` pattern lets the non-greedy match close on the
// nearest alternative rather than its own matching tag (e.g. a <head> block
// closing early at a nested </script>). Passing script/style first empties
// <head> of anything that could confuse the second pass.
var (
	scriptStyleRe = regexp.MustCompile(`(?is)<(script|style)[^>]*>.*?</(script|style)>`)
	headTagRe     = regexp.MustCompile(`(?is)<head[^>]*>.*?</head>`)
	chromeTagRe   = regexp.MustCompile(`(?is)<(nav|header|footer|form|noscript|aside)[^>]*>.*?</(nav|header|footer|form|noscript|aside)>`)

	titleTagRe   = regexp.MustCompile(`(?is)<title[^>]*>(.*?)</title>`)
	articleTagRe = regexp.MustCompile(`(?is)<article[^>]*>(.*?)</article>`)
	paragraphRe  = regexp.MustCompile(`(?is)<p[^>]*>(.*?)</p>`)
)

// Article fetches an article page and extracts readable title/body text for
// on-demand full translation (`csw news article`). Stateless — safe for
// concurrent use.
type Article struct {
	hc *http.Client
}

// NewArticle returns a ready-to-use article fetcher.
func NewArticle() *Article {
	return &Article{hc: &http.Client{}}
}

// FetchArticle downloads pageURL and extracts a readable title + body:
// strips script/style/nav/boilerplate, prefers text inside <article>
// (falling back to every <p> on the page when no <article> element is
// present), collapses whitespace within each paragraph, joins paragraphs
// with a blank line, and caps the result at maxArticleTextChars. Returns an
// error if the page can't be fetched or no readable text is found.
func (a *Article) FetchArticle(ctx context.Context, pageURL string) (title, body string, err error) {
	fetchCtx, cancel := context.WithTimeout(ctx, articleFetchTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(fetchCtx, http.MethodGet, pageURL, nil)
	if err != nil {
		return "", "", fmt.Errorf("build request for %s: %w", pageURL, err)
	}
	req.Header.Set("User-Agent", feedUserAgent)

	resp, err := a.hc.Do(req)
	if err != nil {
		return "", "", fmt.Errorf("fetch %s: %w", pageURL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return "", "", fmt.Errorf("fetch %s: status %d", pageURL, resp.StatusCode)
	}

	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxArticleHTMLBytes))
	if err != nil {
		return "", "", fmt.Errorf("read %s: %w", pageURL, err)
	}

	title = extractTitle(string(raw))
	body = extractBody(string(raw))
	if body == "" {
		return title, "", fmt.Errorf("no readable article text found at %s", pageURL)
	}
	return title, body, nil
}

// extractTitle pulls the page's <title> text, HTML-unescaped and trimmed.
func extractTitle(rawHTML string) string {
	m := titleTagRe.FindStringSubmatch(rawHTML)
	if m == nil {
		return ""
	}
	return strings.TrimSpace(stripHTMLToText(m[1]))
}

// extractBody strips boilerplate blocks, then extracts paragraph text —
// preferring content inside <article> when present, falling back to every
// <p> on the page otherwise — and caps the joined result at
// maxArticleTextChars.
func extractBody(rawHTML string) string {
	cleaned := scriptStyleRe.ReplaceAllString(rawHTML, " ")
	cleaned = headTagRe.ReplaceAllString(cleaned, " ")
	cleaned = chromeTagRe.ReplaceAllString(cleaned, " ")

	source := cleaned
	if m := articleTagRe.FindStringSubmatch(cleaned); m != nil {
		source = m[1]
	}

	paras := paragraphRe.FindAllStringSubmatch(source, -1)
	var texts []string
	for _, p := range paras {
		t := strings.TrimSpace(stripHTMLToText(p[1]))
		if t != "" {
			texts = append(texts, t)
		}
	}

	var body string
	if len(texts) > 0 {
		body = strings.Join(texts, "\n\n")
	} else {
		// No <p> tags found (some pages, e.g. plain-text blog posts,
		// don't use them) — fall back to the whole cleaned source as one
		// blob, still better than returning nothing.
		body = strings.TrimSpace(stripHTMLToText(source))
	}
	return truncateRunes(body, maxArticleTextChars)
}

// stripHTMLToText removes tags and unescapes entities, collapsing runs of
// whitespace to single spaces — mirrors rss.go's itemDescription cleanup,
// factored out here since both need identical HTML-to-plain-text handling.
func stripHTMLToText(raw string) string {
	text := htmlTagRe.ReplaceAllString(raw, " ")
	text = html.UnescapeString(text)
	return strings.Join(strings.Fields(text), " ")
}
