// Package usagehist persists a rolling record of per-month token totals so the
// Month view keeps a real multi-month history even after Claude Code prunes the
// underlying JSONL session logs (which only reach back a few weeks on an active
// machine). The live scan can only see what is still on disk; this store
// remembers the high-water total for every month it has ever observed.
package usagehist

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// monthKey format — calendar month in the report's local zone.
const monthKey = "2006-01"

// Store is a tiny JSON-file map of "YYYY-MM" → the largest UsageBucket seen for
// that month. Safe for concurrent Merge calls.
type Store struct {
	path string
	mu   sync.Mutex
}

// NewStore resolves the default on-disk location under the app support dir.
func NewStore() (*Store, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	p := filepath.Join(home, "Library", "Application Support",
		"claude-swap-widget", "usage", "monthly-history.json")
	return &Store{path: p}, nil
}

// newStoreAt builds a store rooted at an explicit file — for tests.
func newStoreAt(path string) *Store { return &Store{path: path} }

// Merge folds the persisted history into report.Monthly and records any new
// per-month highs. For each month it keeps the larger of the live scan and the
// stored value (by TotalTokens): the current month grows as it accrues, while
// completed months survive after their JSONL is pruned to zero. The report's
// Monthly buckets are rewritten in place with the merged (backfilled) values.
//
// Best-effort by contract: callers ignore the error so a history-file problem
// never breaks the usage report itself.
func (s *Store) Merge(report *domain.UsageStatsReport) error {
	if report == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	m, err := s.load()
	if err != nil {
		return err
	}

	dirty := false
	for i := range report.Monthly {
		tb := &report.Monthly[i]
		key := tb.Start.Format(monthKey)
		stored, ok := m[key]

		// Backfill the report from history when the live scan lost data to
		// pruning (stored total exceeds what is currently on disk).
		if ok && stored.TotalTokens > tb.Bucket.TotalTokens {
			tb.Bucket = stored
		}

		// Record a new high-water mark. Never persist empty months — they add
		// no history and would just clutter the file.
		best := tb.Bucket
		if best.TotalTokens > 0 && best.TotalTokens > stored.TotalTokens {
			m[key] = best
			dirty = true
		}
	}

	if !dirty {
		return nil
	}
	return s.save(m)
}

// load reads the map, tolerating a missing or corrupt file by starting fresh —
// a bad history file must never take down usage stats.
func (s *Store) load() (map[string]domain.UsageBucket, error) {
	b, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]domain.UsageBucket{}, nil
	}
	if err != nil {
		return nil, err
	}
	m := map[string]domain.UsageBucket{}
	if err := json.Unmarshal(b, &m); err != nil {
		return map[string]domain.UsageBucket{}, nil
	}
	return m, nil
}

// save writes the map atomically (temp + rename) with owner-only perms.
func (s *Store) save(m map[string]domain.UsageBucket) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}
