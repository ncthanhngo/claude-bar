package newsstore

import (
	"context"
	"path/filepath"
	"testing"
)

func TestStore_LoadRetention_EmptyStateIsEmptyMapNotNil(t *testing.T) {
	s := NewStoreAt(filepath.Join(t.TempDir(), "news"))
	m, err := s.LoadRetention(context.Background())
	if err != nil {
		t.Fatalf("LoadRetention: %v", err)
	}
	if m == nil {
		t.Error("expected an empty map, not nil")
	}
}

func TestStore_SaveLoadRetention_RoundTrip(t *testing.T) {
	s := NewStoreAt(filepath.Join(t.TempDir(), "news"))
	ctx := context.Background()

	want := map[string]string{"https://example.com/a": "2026-07-20T00:00:00Z"}
	if err := s.SaveRetention(ctx, want); err != nil {
		t.Fatalf("SaveRetention: %v", err)
	}

	got, err := s.LoadRetention(ctx)
	if err != nil {
		t.Fatalf("LoadRetention: %v", err)
	}
	if got["https://example.com/a"] != want["https://example.com/a"] {
		t.Errorf("got = %+v, want %+v", got, want)
	}
}
