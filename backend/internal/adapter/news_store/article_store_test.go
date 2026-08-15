package newsstore

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

func TestStore_LoadArticle_MissingIsOkFalseNoError(t *testing.T) {
	s := NewStoreAt(filepath.Join(t.TempDir(), "news"))
	article, ok, err := s.LoadArticle(context.Background(), "https://example.com/never-fetched")
	if err != nil {
		t.Fatalf("LoadArticle: %v", err)
	}
	if ok || article != nil {
		t.Errorf("want ok=false, article=nil for an uncached URL, got ok=%v article=%+v", ok, article)
	}
}

func TestStore_SaveLoadArticle_RoundTripAtSHA1Path(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "news")
	s := NewStoreAt(dir)
	ctx := context.Background()

	url := "https://simonwillison.net/2026/Aug/15/sighting-391300422/"
	article := &port.NewsArticle{
		URL: url, TitleVI: "Tiêu đề", ContentVI: "Nội dung đầy đủ.",
		Provider: "ollama", Model: "qwen2.5:14b", FetchedAt: "2026-08-15T10:00:00Z", OK: true,
	}
	if err := s.SaveArticle(ctx, article); err != nil {
		t.Fatalf("SaveArticle: %v", err)
	}

	// Cache file must live exactly at news/articles/<sha1(url)>.json per the
	// contract, so a Swift client fetching the same URL independently could
	// derive the same path.
	sum := sha1.Sum([]byte(url))
	wantPath := filepath.Join(dir, "articles", hex.EncodeToString(sum[:])+".json")
	if _, statErr := os.Stat(wantPath); statErr != nil {
		t.Fatalf("expected cache file at %s: %v", wantPath, statErr)
	}

	loaded, ok, err := s.LoadArticle(ctx, url)
	if err != nil {
		t.Fatalf("LoadArticle: %v", err)
	}
	if !ok {
		t.Fatal("expected ok=true after a save")
	}
	if loaded.ContentVI != "Nội dung đầy đủ." || loaded.Provider != "ollama" {
		t.Errorf("loaded = %+v", loaded)
	}
}

func TestStore_SaveArticle_CachesFailureToo(t *testing.T) {
	s := NewStoreAt(filepath.Join(t.TempDir(), "news"))
	ctx := context.Background()
	url := "https://example.com/broken"

	failed := &port.NewsArticle{URL: url, OK: false, Error: "fetch article: status 404", FetchedAt: "2026-08-15T10:00:00Z"}
	if err := s.SaveArticle(ctx, failed); err != nil {
		t.Fatalf("SaveArticle: %v", err)
	}

	loaded, ok, err := s.LoadArticle(ctx, url)
	if err != nil {
		t.Fatalf("LoadArticle: %v", err)
	}
	if !ok {
		t.Fatal("expected a cached (failed) result to still be served back")
	}
	if loaded.OK || loaded.ContentVI != "" || loaded.Error == "" {
		t.Errorf("loaded = %+v", loaded)
	}
}
