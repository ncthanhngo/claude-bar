package newsstore

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

func (s *Store) savedFile() string { return filepath.Join(s.dir, "saved.json") }

// LoadSaved returns the persisted permanent-bookmark set, or an
// empty-but-valid SavedFeed (items/repos as [], never null) if nothing has
// been saved yet.
func (s *Store) LoadSaved(_ context.Context) (*port.SavedFeed, error) {
	var saved port.SavedFeed
	ok, err := readJSON(s.savedFile(), &saved)
	if err != nil {
		return nil, err
	}
	if !ok {
		saved = port.SavedFeed{}
	}
	normalizeSaved(&saved)
	return &saved, nil
}

func (s *Store) writeSaved(saved *port.SavedFeed) error {
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return fmt.Errorf("news store: mkdir: %w", err)
	}
	normalizeSaved(saved)
	return writeJSONAtomic(s.savedFile(), saved)
}

// SaveSavedItem upserts item into the permanent bookmark set, idempotent by
// ID — saving an already-saved item replaces its stored copy (e.g. a
// refreshed translation) rather than duplicating it.
func (s *Store) SaveSavedItem(ctx context.Context, item port.NewsItem) error {
	saved, err := s.LoadSaved(ctx)
	if err != nil {
		return err
	}
	replaced := false
	for i := range saved.Items {
		if saved.Items[i].ID == item.ID {
			saved.Items[i] = item
			replaced = true
			break
		}
	}
	if !replaced {
		saved.Items = append(saved.Items, item)
	}
	return s.writeSaved(saved)
}

// SaveSavedRepo mirrors SaveSavedItem for repos.
func (s *Store) SaveSavedRepo(ctx context.Context, repo port.Repo) error {
	saved, err := s.LoadSaved(ctx)
	if err != nil {
		return err
	}
	replaced := false
	for i := range saved.Repos {
		if saved.Repos[i].ID == repo.ID {
			saved.Repos[i] = repo
			replaced = true
			break
		}
	}
	if !replaced {
		saved.Repos = append(saved.Repos, repo)
	}
	return s.writeSaved(saved)
}

// RemoveSavedItem drops the item with id from the bookmark set. Removing an
// id that isn't saved is a no-op, not an error — unsave is idempotent.
func (s *Store) RemoveSavedItem(ctx context.Context, id string) error {
	saved, err := s.LoadSaved(ctx)
	if err != nil {
		return err
	}
	out := make([]port.NewsItem, 0, len(saved.Items))
	for _, it := range saved.Items {
		if it.ID != id {
			out = append(out, it)
		}
	}
	saved.Items = out
	return s.writeSaved(saved)
}

// RemoveSavedRepo mirrors RemoveSavedItem for repos.
func (s *Store) RemoveSavedRepo(ctx context.Context, id string) error {
	saved, err := s.LoadSaved(ctx)
	if err != nil {
		return err
	}
	out := make([]port.Repo, 0, len(saved.Repos))
	for _, r := range saved.Repos {
		if r.ID != id {
			out = append(out, r)
		}
	}
	saved.Repos = out
	return s.writeSaved(saved)
}

// normalizeSaved guarantees Items/Repos serialise as [] — never null —
// matching the rest of the store's nil-slice convention.
func normalizeSaved(f *port.SavedFeed) {
	if f.Items == nil {
		f.Items = []port.NewsItem{}
	}
	if f.Repos == nil {
		f.Repos = []port.Repo{}
	}
}
