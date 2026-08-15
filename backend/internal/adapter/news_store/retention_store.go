package newsstore

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
)

func (s *Store) retentionFile() string { return filepath.Join(s.dir, "retention.json") }

// LoadRetention returns the persisted first-seen-timestamp map (see
// usecase/news.MergeRetain), or an empty map if nothing has been fetched
// yet — never nil, so callers can write into it directly.
func (s *Store) LoadRetention(_ context.Context) (map[string]string, error) {
	var m map[string]string
	ok, err := readJSON(s.retentionFile(), &m)
	if err != nil {
		return nil, err
	}
	if !ok || m == nil {
		m = map[string]string{}
	}
	return m, nil
}

// SaveRetention atomically persists the first-seen-timestamp map.
func (s *Store) SaveRetention(_ context.Context, firstSeen map[string]string) error {
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return fmt.Errorf("news store: mkdir: %w", err)
	}
	if firstSeen == nil {
		firstSeen = map[string]string{}
	}
	return writeJSONAtomic(s.retentionFile(), firstSeen)
}
