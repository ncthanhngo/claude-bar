package mcp

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
)

func TestGitLabInstanceStorePutListDelete(t *testing.T) {
	path := filepath.Join(t.TempDir(), "gitlab.json")
	s := NewGitLabInstanceStore(path)
	ctx := context.Background()

	saved, err := s.Put(ctx, GitLabInstance{Name: "vault", BaseURL: "https://vault.example.com/api/v4"})
	if err != nil {
		t.Fatalf("put: %v", err)
	}
	if saved.ID == "" {
		t.Error("expected generated ID")
	}
	list, _ := s.List(ctx)
	if len(list) != 1 {
		t.Fatalf("want 1, got %d", len(list))
	}
	if err := s.Delete(ctx, saved.ID); err != nil {
		t.Fatal(err)
	}
	list, _ = s.List(ctx)
	if len(list) != 0 {
		t.Errorf("after Delete, want 0, got %d", len(list))
	}
}

func TestGitLabInstanceStoreRejectsHTTPAndMissingName(t *testing.T) {
	s := NewGitLabInstanceStore(filepath.Join(t.TempDir(), "g.json"))
	ctx := context.Background()
	if _, err := s.Put(ctx, GitLabInstance{Name: "", BaseURL: "https://x.example.com"}); err == nil {
		t.Errorf("missing name should fail")
	}
	if _, err := s.Put(ctx, GitLabInstance{Name: "bad", BaseURL: "http://no-tls.example.com"}); err == nil {
		t.Errorf("http:// baseUrl should fail")
	}
}

func TestGitLabInstanceStoreResolve(t *testing.T) {
	s := NewGitLabInstanceStore(filepath.Join(t.TempDir(), "g.json"))
	ctx := context.Background()
	a, _ := s.Put(ctx, GitLabInstance{Name: "alpha", BaseURL: "https://alpha.example.com/api/v4"})
	_, _ = s.Put(ctx, GitLabInstance{Name: "beta", BaseURL: "https://beta.example.com/api/v4"})

	// Resolve by id.
	g, err := s.Resolve(ctx, a.ID)
	if err != nil || g.Name != "alpha" {
		t.Errorf("resolve by id: %v %+v", err, g)
	}
	// Resolve by name (case-insensitive).
	g, err = s.Resolve(ctx, "BETA")
	if err != nil || g.Name != "beta" {
		t.Errorf("resolve by name: %v %+v", err, g)
	}
	// Ambiguous: no ref + multiple instances.
	if _, err := s.Resolve(ctx, ""); err == nil || !strings.Contains(err.Error(), "ambiguous") {
		t.Errorf("expected ambiguous error, got %v", err)
	}
}

func TestGitLabInstanceStoreSingleInstanceImplicitResolve(t *testing.T) {
	s := NewGitLabInstanceStore(filepath.Join(t.TempDir(), "g.json"))
	ctx := context.Background()
	_, _ = s.Put(ctx, GitLabInstance{Name: "solo", BaseURL: "https://solo.example.com/api/v4"})
	g, err := s.Resolve(ctx, "")
	if err != nil || g.Name != "solo" {
		t.Errorf("single instance + empty ref should resolve to that one: %v %+v", err, g)
	}
}
