package news

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
)

// NewsManifest is the small sidecar a Master publishes next to news.json so
// a Client can verify integrity (Hash) and reject stale/rolled-back copies
// (Seq) before trusting the relay content. Internal to the Go master/client
// SSH relay only — not part of the Swift-facing NewsFeed contract.
type NewsManifest struct {
	SchemaVersion int    `json:"schemaVersion"`
	Seq           int64  `json:"seq"`
	Hash          string `json:"hash"`
	GeneratedAt   string `json:"generatedAt"`
}

// newsDataDir mirrors adapter/news_store.NewStore()'s path convention.
// Duplicated here (rather than importing the store package for a directory
// string) to keep the P4 relay code decoupled from the P2/P3 store adapter;
// both must stay in sync if the data dir ever moves.
func newsDataDir() string {
	return filepath.Join(adapter.WidgetDataDir(), "news")
}

func localFeedPathIn(dir string) string     { return filepath.Join(dir, "news.json") }
func localManifestPathIn(dir string) string { return filepath.Join(dir, "manifest.json") }

// computeManifest hashes the exact snapshot bytes and derives Seq from the
// snapshot's own GeneratedAt timestamp (so Seq stays monotonic across
// fetches regardless of when publish happens to run), falling back to the
// given wall-clock `now` when the snapshot has no parseable GeneratedAt.
func computeManifest(newsBytes []byte, now time.Time) NewsManifest {
	var probe struct {
		GeneratedAt string `json:"generatedAt"`
	}
	_ = json.Unmarshal(newsBytes, &probe)

	seq := now.Unix()
	generatedAt := probe.GeneratedAt
	if generatedAt != "" {
		if t, err := time.Parse(time.RFC3339, generatedAt); err == nil {
			seq = t.Unix()
		}
	} else {
		generatedAt = now.UTC().Format(time.RFC3339)
	}

	sum := sha256.Sum256(newsBytes)
	return NewsManifest{
		SchemaVersion: 1,
		Seq:           seq,
		Hash:          hex.EncodeToString(sum[:]),
		GeneratedAt:   generatedAt,
	}
}

// readLocalManifest returns the cached manifest from the last successful
// pull under dir. ok=false (no error) means no pull has ever succeeded on
// this machine — the anti-rollback check treats that as "accept anything",
// mirroring usecase/cloud_pull.go's state-zero rule.
func readLocalManifest(dir string) (m NewsManifest, ok bool, err error) {
	b, err := os.ReadFile(localManifestPathIn(dir))
	if err != nil {
		if os.IsNotExist(err) {
			return NewsManifest{}, false, nil
		}
		return NewsManifest{}, false, fmt.Errorf("read local manifest: %w", err)
	}
	if err := json.Unmarshal(b, &m); err != nil {
		return NewsManifest{}, false, fmt.Errorf("parse local manifest: %w", err)
	}
	return m, true, nil
}

// writeLocalManifestAtomic persists m under dir via temp-file → rename,
// matching the atomic-write convention the rest of the news store uses.
func writeLocalManifestAtomic(dir string, m NewsManifest) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("mkdir news dir: %w", err)
	}
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal manifest: %w", err)
	}
	path := localManifestPathIn(dir)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return fmt.Errorf("write temp manifest: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return fmt.Errorf("rename manifest: %w", err)
	}
	return nil
}
