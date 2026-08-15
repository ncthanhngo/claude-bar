package newsstore

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

func TestStore_SavedEmptyStateHasNoNullSlices(t *testing.T) {
	s := NewStoreAt(filepath.Join(t.TempDir(), "news"))
	saved, err := s.LoadSaved(context.Background())
	if err != nil {
		t.Fatalf("LoadSaved: %v", err)
	}
	if saved.Items == nil || saved.Repos == nil {
		t.Errorf("expected empty slices, not nil: %+v", saved)
	}
}

func TestStore_SaveSavedItem_IdempotentByID(t *testing.T) {
	s := NewStoreAt(filepath.Join(t.TempDir(), "news"))
	ctx := context.Background()

	item := port.NewsItem{ID: "abc", Title: "Hello", TitleVI: "Xin chào"}
	if err := s.SaveSavedItem(ctx, item); err != nil {
		t.Fatalf("SaveSavedItem: %v", err)
	}
	// Save again with the same ID but changed content — must replace, not
	// duplicate.
	item.TitleVI = "Xin chào (updated)"
	if err := s.SaveSavedItem(ctx, item); err != nil {
		t.Fatalf("SaveSavedItem (2nd): %v", err)
	}

	saved, err := s.LoadSaved(ctx)
	if err != nil {
		t.Fatalf("LoadSaved: %v", err)
	}
	if len(saved.Items) != 1 {
		t.Fatalf("want 1 item after idempotent save, got %d: %+v", len(saved.Items), saved.Items)
	}
	if saved.Items[0].TitleVI != "Xin chào (updated)" {
		t.Errorf("expected the second save to replace the first, got %+v", saved.Items[0])
	}
}

func TestStore_SaveSavedRepo_IdempotentByID(t *testing.T) {
	s := NewStoreAt(filepath.Join(t.TempDir(), "news"))
	ctx := context.Background()

	repo := port.Repo{ID: "ollama/ollama", FullName: "ollama/ollama", Stars: 100}
	if err := s.SaveSavedRepo(ctx, repo); err != nil {
		t.Fatalf("SaveSavedRepo: %v", err)
	}
	repo.Stars = 200
	if err := s.SaveSavedRepo(ctx, repo); err != nil {
		t.Fatalf("SaveSavedRepo (2nd): %v", err)
	}

	saved, err := s.LoadSaved(ctx)
	if err != nil {
		t.Fatalf("LoadSaved: %v", err)
	}
	if len(saved.Repos) != 1 || saved.Repos[0].Stars != 200 {
		t.Errorf("want 1 repo with updated stars, got %+v", saved.Repos)
	}
}

func TestStore_RemoveSavedItem_IsIdempotent(t *testing.T) {
	s := NewStoreAt(filepath.Join(t.TempDir(), "news"))
	ctx := context.Background()

	if err := s.SaveSavedItem(ctx, port.NewsItem{ID: "a"}); err != nil {
		t.Fatalf("SaveSavedItem: %v", err)
	}
	if err := s.SaveSavedItem(ctx, port.NewsItem{ID: "b"}); err != nil {
		t.Fatalf("SaveSavedItem: %v", err)
	}
	if err := s.RemoveSavedItem(ctx, "a"); err != nil {
		t.Fatalf("RemoveSavedItem: %v", err)
	}
	// Removing an id that was never saved (or already removed) must not error.
	if err := s.RemoveSavedItem(ctx, "a"); err != nil {
		t.Fatalf("RemoveSavedItem (already gone): %v", err)
	}

	saved, err := s.LoadSaved(ctx)
	if err != nil {
		t.Fatalf("LoadSaved: %v", err)
	}
	if len(saved.Items) != 1 || saved.Items[0].ID != "b" {
		t.Errorf("want only item b left, got %+v", saved.Items)
	}
}

func TestStore_RemoveSavedRepo_IsIdempotent(t *testing.T) {
	s := NewStoreAt(filepath.Join(t.TempDir(), "news"))
	ctx := context.Background()

	if err := s.SaveSavedRepo(ctx, port.Repo{ID: "x/y"}); err != nil {
		t.Fatalf("SaveSavedRepo: %v", err)
	}
	if err := s.RemoveSavedRepo(ctx, "x/y"); err != nil {
		t.Fatalf("RemoveSavedRepo: %v", err)
	}
	if err := s.RemoveSavedRepo(ctx, "x/y"); err != nil {
		t.Fatalf("RemoveSavedRepo (already gone): %v", err)
	}

	saved, err := s.LoadSaved(ctx)
	if err != nil {
		t.Fatalf("LoadSaved: %v", err)
	}
	if len(saved.Repos) != 0 {
		t.Errorf("want no repos left, got %+v", saved.Repos)
	}
}

// TestStore_SavedIndependentOfFeed proves the saved store is a separate
// file from news.json — a SaveFeed call (the 30-day-retention path) must
// never touch or clear saved bookmarks.
func TestStore_SavedIndependentOfFeed(t *testing.T) {
	s := NewStoreAt(filepath.Join(t.TempDir(), "news"))
	ctx := context.Background()

	if err := s.SaveSavedItem(ctx, port.NewsItem{ID: "keep-forever"}); err != nil {
		t.Fatalf("SaveSavedItem: %v", err)
	}
	if err := s.SaveFeed(ctx, &port.NewsFeed{}); err != nil {
		t.Fatalf("SaveFeed: %v", err)
	}

	saved, err := s.LoadSaved(ctx)
	if err != nil {
		t.Fatalf("LoadSaved: %v", err)
	}
	if len(saved.Items) != 1 || saved.Items[0].ID != "keep-forever" {
		t.Errorf("SaveFeed must not affect the saved store, got %+v", saved.Items)
	}
}
