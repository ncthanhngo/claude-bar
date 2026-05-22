// Package briefingstore persists Briefing JSON files under the widget data dir.
package briefingstore

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/usecase/briefing"
)

// ErrNotFound means no briefing exists for that date.
var ErrNotFound = errors.New("briefing not found")

// Store handles persistence of per-day briefing files.
type Store struct {
	dir string
}

// New constructs a Store backed by the canonical briefings directory.
func New() (*Store, error) {
	d, err := briefing.Dir()
	if err != nil {
		return nil, err
	}
	return &Store{dir: d}, nil
}

// NewAt is for tests.
func NewAt(dir string) *Store { return &Store{dir: dir} }

// Save writes the briefing JSON atomically (tmp + rename).
func (s *Store) Save(b *briefing.Briefing) error {
	if b == nil {
		return errors.New("nil briefing")
	}
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return err
	}
	path := filepath.Join(s.dir, b.Date+".json")
	tmp := path + ".tmp"

	data, err := json.MarshalIndent(b, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Load reads a briefing by date. Returns ErrNotFound if missing.
func (s *Store) Load(date string) (*briefing.Briefing, error) {
	path := filepath.Join(s.dir, date+".json")
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	var b briefing.Briefing
	if err := json.Unmarshal(data, &b); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	return &b, nil
}

// ListDates returns YYYY-MM-DD strings sorted descending (newest first).
func (s *Store) ListDates() ([]string, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	dates := []string{}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasSuffix(name, ".json") || strings.HasPrefix(name, ".") {
			continue
		}
		base := strings.TrimSuffix(name, ".json")
		if len(base) == 10 && base[4] == '-' && base[7] == '-' {
			dates = append(dates, base)
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(dates)))
	return dates, nil
}

// Prune deletes files older than maxAgeDays (by file's date stamp).
func (s *Store) Prune(maxAgeDays int) (int, error) {
	dates, err := s.ListDates()
	if err != nil {
		return 0, err
	}
	cutoff := time.Now().AddDate(0, 0, -maxAgeDays).Format("2006-01-02")
	n := 0
	for _, d := range dates {
		if d < cutoff {
			path := filepath.Join(s.dir, d+".json")
			if err := os.Remove(path); err == nil {
				n++
			}
		}
	}
	return n, nil
}

// ToggleAction sets the Done flag for one action and re-saves the file.
func (s *Store) ToggleAction(date, actionID string, done bool) error {
	b, err := s.Load(date)
	if err != nil {
		return err
	}
	for i := range b.Actions {
		if b.Actions[i].ID == actionID {
			b.Actions[i].Done = done
			return s.Save(b)
		}
	}
	return fmt.Errorf("action %s not found in briefing %s", actionID, date)
}
