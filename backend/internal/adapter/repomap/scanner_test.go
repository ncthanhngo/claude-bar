package repomap

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func makeFakeRepo(t *testing.T, root, name, originURL string) string {
	t.Helper()
	dir := filepath.Join(root, name)
	if err := os.MkdirAll(filepath.Join(dir, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	cfg := `[core]
	repositoryformatversion = 0
[remote "origin"]
	url = ` + originURL + `
	fetch = +refs/heads/*:refs/remotes/origin/*
`
	if err := os.WriteFile(filepath.Join(dir, ".git", "config"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestScannerFindsReposAndReadsOrigin(t *testing.T) {
	root := t.TempDir()
	repo1 := makeFakeRepo(t, root, "alpha", "git@github.com:soi/alpha.git")
	repo2 := makeFakeRepo(t, root, "beta", "https://github.com/soi/beta")

	m, err := Scanner{Roots: []string{root}, MaxDepth: 2}.Scan()
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Entries) != 2 {
		t.Fatalf("want 2 entries, got %d (%+v)", len(m.Entries), m.Entries)
	}

	paths := map[string]bool{}
	for _, e := range m.Entries {
		paths[e.LocalPath] = true
	}
	if !paths[repo1] || !paths[repo2] {
		t.Errorf("missing path: got %v", paths)
	}
}

func TestNormaliseOriginAcrossUrlForms(t *testing.T) {
	canonical := "github.com/soi/repo"
	cases := []string{
		"git@github.com:soi/repo.git",
		"https://github.com/soi/repo.git",
		"https://github.com/soi/repo",
		"ssh://git@github.com/soi/repo",
	}
	for _, in := range cases {
		if got := NormaliseOrigin(in); got != canonical {
			t.Errorf("%q → %q, want %q", in, got, canonical)
		}
	}
}

func TestMapLookupFindsByAnyOriginForm(t *testing.T) {
	root := t.TempDir()
	repo := makeFakeRepo(t, root, "claude-bar", "git@github.com:soi/claude-bar.git")
	m, err := Scanner{Roots: []string{root}}.Scan()
	if err != nil {
		t.Fatal(err)
	}
	if got := m.Lookup("https://github.com/soi/claude-bar.git"); got != repo {
		t.Errorf("Lookup via https form failed: %q vs %q", got, repo)
	}
	if got := m.Lookup("git@github.com:soi/claude-bar.git"); got != repo {
		t.Errorf("Lookup via ssh form failed: %q", got)
	}
	if got := m.Lookup("git@github.com:other/repo.git"); got != "" {
		t.Errorf("unknown origin should return empty, got %q", got)
	}
}

func TestScannerSavesAndLoadsRoundTrip(t *testing.T) {
	root := t.TempDir()
	makeFakeRepo(t, root, "x", "https://github.com/a/x")
	m, _ := Scanner{Roots: []string{root}}.Scan()

	out := filepath.Join(t.TempDir(), "repo-map.json")
	if err := m.Save(out); err != nil {
		t.Fatalf("save: %v", err)
	}
	loaded, err := Load(out)
	if err != nil || loaded == nil {
		t.Fatalf("load: %v %v", err, loaded)
	}
	if len(loaded.Entries) != len(m.Entries) {
		t.Errorf("round-trip lost entries: %d vs %d", len(loaded.Entries), len(m.Entries))
	}
}

func TestScannerSkipsNodeModulesAndDotDirs(t *testing.T) {
	root := t.TempDir()
	// Bury a fake repo inside node_modules and another inside `.hidden`.
	hidden := filepath.Join(root, ".hidden", "deep")
	_ = os.MkdirAll(filepath.Join(hidden, ".git"), 0o755)
	_ = os.WriteFile(filepath.Join(hidden, ".git", "config"), []byte(`[remote "origin"]
	url = git@github.com:a/b
`), 0o644)
	nm := filepath.Join(root, "node_modules", "pkg")
	_ = os.MkdirAll(filepath.Join(nm, ".git"), 0o755)
	_ = os.WriteFile(filepath.Join(nm, ".git", "config"), []byte(`[remote "origin"]
	url = git@github.com:a/pkg
`), 0o644)
	// Plus one legit repo.
	makeFakeRepo(t, root, "real", "git@github.com:soi/real")

	m, _ := Scanner{Roots: []string{root}, MaxDepth: 3}.Scan()
	if len(m.Entries) != 1 || !strings.HasSuffix(m.Entries[0].LocalPath, "/real") {
		t.Fatalf("expected only the legit repo, got %v", m.Entries)
	}
}
