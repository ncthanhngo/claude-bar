package news

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// fakeArticleFetcher is a minimal ArticleFetcher test double.
type fakeArticleFetcher struct {
	title, body string
	err         error
	calls       int
}

func (f *fakeArticleFetcher) FetchArticle(_ context.Context, _ string) (string, string, error) {
	f.calls++
	return f.title, f.body, f.err
}

func newTestArticleService(fetcher ArticleFetcher, ollama *fakeTranslatingSummarizer, store *fakeNewsStore) *ArticleService {
	router := NewProviderRouter(ollama, nil)
	svc := NewArticleService(fetcher, router, store)
	svc.Now = func() time.Time { return time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC) }
	return svc
}

func TestArticleService_Get_FetchesTranslatesAndCachesOnMiss(t *testing.T) {
	fetcher := &fakeArticleFetcher{title: "English Title", body: "Full body text."}
	ollama := &fakeTranslatingSummarizer{titleVI: "Tiêu đề", contentVI: "Toàn bộ nội dung."}
	store := &fakeNewsStore{}
	svc := newTestArticleService(fetcher, ollama, store)

	article, err := svc.Get(context.Background(), "https://example.com/a", false, port.NewsConfig{Provider: "ollama"})
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !article.OK || article.ContentVI != "Toàn bộ nội dung." || article.Provider != "ollama" {
		t.Errorf("article = %+v", article)
	}
	if fetcher.calls != 1 || ollama.translateCalls != 1 {
		t.Errorf("expected exactly one fetch+translate on a cache miss, got fetch=%d translate=%d", fetcher.calls, ollama.translateCalls)
	}
	if len(store.articles) != 1 {
		t.Errorf("expected the result to be cached, got %d entries", len(store.articles))
	}
}

func TestArticleService_Get_ReturnsCacheWithoutRefetchingByDefault(t *testing.T) {
	fetcher := &fakeArticleFetcher{title: "T", body: "B"}
	ollama := &fakeTranslatingSummarizer{contentVI: "C"}
	store := &fakeNewsStore{}
	svc := newTestArticleService(fetcher, ollama, store)
	ctx := context.Background()

	if _, err := svc.Get(ctx, "https://example.com/a", false, port.NewsConfig{Provider: "ollama"}); err != nil {
		t.Fatalf("Get (1st): %v", err)
	}
	if _, err := svc.Get(ctx, "https://example.com/a", false, port.NewsConfig{Provider: "ollama"}); err != nil {
		t.Fatalf("Get (2nd): %v", err)
	}
	if fetcher.calls != 1 || ollama.translateCalls != 1 {
		t.Errorf("expected the 2nd call to be served from cache, got fetch=%d translate=%d", fetcher.calls, ollama.translateCalls)
	}
}

func TestArticleService_Get_ForceBypassesCache(t *testing.T) {
	fetcher := &fakeArticleFetcher{title: "T", body: "B"}
	ollama := &fakeTranslatingSummarizer{contentVI: "C"}
	store := &fakeNewsStore{}
	svc := newTestArticleService(fetcher, ollama, store)
	ctx := context.Background()

	if _, err := svc.Get(ctx, "https://example.com/a", false, port.NewsConfig{Provider: "ollama"}); err != nil {
		t.Fatalf("Get (1st): %v", err)
	}
	if _, err := svc.Get(ctx, "https://example.com/a", true, port.NewsConfig{Provider: "ollama"}); err != nil {
		t.Fatalf("Get (force): %v", err)
	}
	if fetcher.calls != 2 || ollama.translateCalls != 2 {
		t.Errorf("expected --force to re-fetch+translate, got fetch=%d translate=%d", fetcher.calls, ollama.translateCalls)
	}
}

func TestArticleService_Get_FetchFailureReturnsOKFalseAndCaches(t *testing.T) {
	fetcher := &fakeArticleFetcher{err: errors.New("404")}
	ollama := &fakeTranslatingSummarizer{contentVI: "should not be used"}
	store := &fakeNewsStore{}
	svc := newTestArticleService(fetcher, ollama, store)

	article, err := svc.Get(context.Background(), "https://example.com/broken", false, port.NewsConfig{Provider: "ollama"})
	if err != nil {
		t.Fatalf("Get should not surface a fetch failure as a Go error: %v", err)
	}
	if article.OK || article.ContentVI != "" || article.Error == "" {
		t.Errorf("article = %+v", article)
	}
	if ollama.translateCalls != 0 {
		t.Errorf("translate should never be called after a fetch failure, calls=%d", ollama.translateCalls)
	}
	if len(store.articles) != 1 {
		t.Error("expected the failure to be cached too, so it isn't retried every call")
	}
}

func TestArticleService_Get_TranslateFailureReturnsOKFalse(t *testing.T) {
	fetcher := &fakeArticleFetcher{title: "T", body: "B"}
	ollama := &fakeTranslatingSummarizer{translateErr: errors.New("ollama down")}
	store := &fakeNewsStore{}
	svc := newTestArticleService(fetcher, ollama, store)

	article, err := svc.Get(context.Background(), "https://example.com/a", false, port.NewsConfig{Provider: "ollama"})
	if err != nil {
		t.Fatalf("Get should not surface a translate failure as a Go error: %v", err)
	}
	if article.OK || article.ContentVI != "" {
		t.Errorf("article = %+v", article)
	}
}

func TestArticleService_Get_RequiresURL(t *testing.T) {
	svc := newTestArticleService(&fakeArticleFetcher{}, &fakeTranslatingSummarizer{}, &fakeNewsStore{})
	if _, err := svc.Get(context.Background(), "", false, port.NewsConfig{}); err == nil {
		t.Fatal("expected an error for an empty URL")
	}
}
