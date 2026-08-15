package news

import (
	"context"
	"fmt"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// ArticleFetcher fetches + extracts a readable title/body from an article
// URL. Implementation: adapter/newsfetch.Article.
type ArticleFetcher interface {
	FetchArticle(ctx context.Context, pageURL string) (title, body string, err error)
}

// ArticleService implements the on-demand full-article translation flow
// behind `csw news article`: fetch + extract the page, translate the full
// body to Vietnamese via the provider router, and cache the result (both on
// success and failure) so repeat requests for the same URL don't re-pay the
// fetch+translate cost.
type ArticleService struct {
	Fetcher ArticleFetcher
	Router  *ProviderRouter
	Store   port.NewsStore
	Now     func() time.Time
}

// NewArticleService wires the three collaborators, defaulting Now to
// time.Now.
func NewArticleService(fetcher ArticleFetcher, router *ProviderRouter, store port.NewsStore) *ArticleService {
	return &ArticleService{Fetcher: fetcher, Router: router, Store: store, Now: func() time.Time { return time.Now().UTC() }}
}

// Get returns the cached translation for url unless force is set (or
// nothing is cached yet), in which case it fetches, extracts, translates,
// and persists a fresh result — even on failure (ok:false + error), so a
// broken URL isn't silently re-fetched on every call absent --force.
func (a *ArticleService) Get(ctx context.Context, url string, force bool, cfg port.NewsConfig) (*port.NewsArticle, error) {
	if url == "" {
		return nil, fmt.Errorf("url is required")
	}
	if !force {
		cached, ok, err := a.Store.LoadArticle(ctx, url)
		if err != nil {
			return nil, fmt.Errorf("load article cache: %w", err)
		}
		if ok {
			return cached, nil
		}
	}

	result := a.fetchAndTranslate(ctx, url, cfg)
	if err := a.Store.SaveArticle(ctx, result); err != nil {
		return nil, fmt.Errorf("save article cache: %w", err)
	}
	return result, nil
}

func (a *ArticleService) fetchAndTranslate(ctx context.Context, url string, cfg port.NewsConfig) *port.NewsArticle {
	now := a.now().Format(time.RFC3339)

	title, body, err := a.Fetcher.FetchArticle(ctx, url)
	if err != nil {
		return &port.NewsArticle{URL: url, FetchedAt: now, OK: false, Error: fmt.Sprintf("fetch article: %v", err)}
	}

	result, err := a.Router.Translate(ctx, port.ArticleTranslateInput{Title: title, Body: body}, cfg)
	if err != nil {
		return &port.NewsArticle{URL: url, FetchedAt: now, OK: false, Error: fmt.Sprintf("translate article: %v", err)}
	}

	model := a.Router.ResolveModel(ctx, result.Provider, cfg)
	return &port.NewsArticle{
		URL:       url,
		TitleVI:   result.TitleVI,
		ContentVI: result.ContentVI,
		Provider:  result.Provider,
		Model:     model,
		FetchedAt: now,
		OK:        true,
	}
}

func (a *ArticleService) now() time.Time {
	if a.Now != nil {
		return a.Now()
	}
	return time.Now().UTC()
}
