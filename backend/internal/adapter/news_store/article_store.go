package newsstore

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

func (s *Store) articlesDir() string { return filepath.Join(s.dir, "articles") }

// articleFile derives the cache path for url per the contract:
// news/articles/<sha1(url)>.json. sha1 here is a cache key, not a security
// boundary.
func (s *Store) articleFile(url string) string {
	sum := sha1.Sum([]byte(url)) //nolint:gosec // cache key only, not security-sensitive
	return filepath.Join(s.articlesDir(), hex.EncodeToString(sum[:])+".json")
}

// LoadArticle returns the cached on-demand translation for url, if any.
// ok=false (no error) means nothing has been cached for this URL yet.
func (s *Store) LoadArticle(_ context.Context, url string) (*port.NewsArticle, bool, error) {
	var article port.NewsArticle
	ok, err := readJSON(s.articleFile(url), &article)
	if err != nil {
		return nil, false, err
	}
	if !ok {
		return nil, false, nil
	}
	return &article, true, nil
}

// SaveArticle atomically persists article at its sha1(url) cache path. Both
// successful and failed (ok:false) results are cached, so a broken URL
// isn't silently re-fetched on every call absent --force.
func (s *Store) SaveArticle(_ context.Context, article *port.NewsArticle) error {
	if err := os.MkdirAll(s.articlesDir(), 0o700); err != nil {
		return fmt.Errorf("news store: mkdir articles: %w", err)
	}
	return writeJSONAtomic(s.articleFile(article.URL), article)
}
