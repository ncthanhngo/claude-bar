package news

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"testing"

	sshadp "github.com/soi/claude-swap-widget/backend/internal/adapter/ssh"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// fakeHostGetter satisfies hostGetter without touching the real hosts.json.
type fakeHostGetter struct {
	host *sshadp.TrackedHost
	err  error
}

func (f fakeHostGetter) Get(_ context.Context, _ string) (*sshadp.TrackedHost, error) {
	return f.host, f.err
}

// fakeNewsStore satisfies port.NewsStore in-memory, standing in for the real
// atomic-JSON-file store so tests never touch the app-support dir.
type fakeNewsStore struct {
	saved     *port.NewsFeed
	saveCalls int
	saveErr   error
}

func (f *fakeNewsStore) LoadFeed(_ context.Context) (*port.NewsFeed, error) { return f.saved, nil }
func (f *fakeNewsStore) SaveFeed(_ context.Context, feed *port.NewsFeed) error {
	f.saveCalls++
	if f.saveErr != nil {
		return f.saveErr
	}
	cp := *feed
	f.saved = &cp
	return nil
}
func (f *fakeNewsStore) LoadConfig(_ context.Context) (*port.NewsConfig, error) {
	return &port.NewsConfig{}, nil
}
func (f *fakeNewsStore) SaveConfig(_ context.Context, _ *port.NewsConfig) error { return nil }

var _ port.NewsStore = (*fakeNewsStore)(nil)

func hashHex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// fakeReadFile returns canned bytes per remote path, ignoring the maxBytes
// cap (tests use small fixtures) — the seam Puller.ReadFile is injected
// through instead of shelling out to a real ssh binary.
func fakeReadFile(byPath map[string]string) remoteReader {
	return func(_ context.Context, _ sshadp.TrackedHost, path string, _ int) (*sshadp.ExecResult, error) {
		body, ok := byPath[path]
		if !ok {
			return &sshadp.ExecResult{ExitCode: 1, Stderr: "no such file"}, nil
		}
		return &sshadp.ExecResult{Stdout: body, ExitCode: 0}, nil
	}
}

func TestPuller_Pull_Success(t *testing.T) {
	newsBytes := []byte(`{"schemaVersion":1,"generatedAt":"2026-08-15T08:00:00Z","role":"master","items":[],"repos":[],"sourcesHealth":{}}`)
	manifest := NewsManifest{SchemaVersion: 1, Seq: 100, Hash: hashHex(newsBytes), GeneratedAt: "2026-08-15T08:00:00Z"}
	manifestBytes, _ := json.Marshal(manifest)

	store := &fakeNewsStore{}
	p := &Puller{
		Hosts: fakeHostGetter{host: &sshadp.TrackedHost{Name: "relay"}},
		ReadFile: fakeReadFile(map[string]string{
			"/relay/manifest.json": string(manifestBytes),
			"/relay/news.json":     string(newsBytes),
		}),
		Store: store,
		Dir:   t.TempDir(),
	}

	feed, err := p.Pull(context.Background(), "relay", "/relay")
	if err != nil {
		t.Fatalf("Pull: %v", err)
	}
	if feed.Role != "client" {
		t.Errorf("Role = %q, want client", feed.Role)
	}
	if store.saveCalls != 1 {
		t.Errorf("SaveFeed calls = %d, want 1", store.saveCalls)
	}

	cached, ok, err := readLocalManifest(p.Dir)
	if err != nil || !ok {
		t.Fatalf("expected local manifest cached, ok=%v err=%v", ok, err)
	}
	if cached.Seq != manifest.Seq {
		t.Errorf("cached seq = %d, want %d", cached.Seq, manifest.Seq)
	}
}

func TestPuller_Pull_HashMismatchRejected(t *testing.T) {
	newsBytes := []byte(`{"generatedAt":"2026-08-15T08:00:00Z","items":[]}`)
	manifest := NewsManifest{SchemaVersion: 1, Seq: 100, Hash: "deadbeef", GeneratedAt: "2026-08-15T08:00:00Z"}
	manifestBytes, _ := json.Marshal(manifest)

	store := &fakeNewsStore{}
	p := &Puller{
		Hosts: fakeHostGetter{host: &sshadp.TrackedHost{Name: "relay"}},
		ReadFile: fakeReadFile(map[string]string{
			"/relay/manifest.json": string(manifestBytes),
			"/relay/news.json":     string(newsBytes),
		}),
		Store: store,
		Dir:   t.TempDir(),
	}

	_, err := p.Pull(context.Background(), "relay", "/relay")
	if err == nil {
		t.Fatal("expected hash-mismatch error, got nil")
	}
	if store.saveCalls != 0 {
		t.Errorf("SaveFeed must not be called on hash mismatch, got %d calls", store.saveCalls)
	}
	if _, ok, _ := readLocalManifest(p.Dir); ok {
		t.Error("local manifest cache must stay untouched on hash mismatch")
	}
}

func TestPuller_Pull_RollbackRejected(t *testing.T) {
	dir := t.TempDir()
	// Seed a local cache at seq=200 (a newer snapshot this Client already saw).
	if err := writeLocalManifestAtomic(dir, NewsManifest{SchemaVersion: 1, Seq: 200, Hash: "prev", GeneratedAt: "2026-08-15T10:00:00Z"}); err != nil {
		t.Fatalf("seed local manifest: %v", err)
	}

	newsBytes := []byte(`{"generatedAt":"2026-08-15T08:00:00Z","items":[]}`)
	manifest := NewsManifest{SchemaVersion: 1, Seq: 100, Hash: hashHex(newsBytes), GeneratedAt: "2026-08-15T08:00:00Z"} // older seq than cached
	manifestBytes, _ := json.Marshal(manifest)

	store := &fakeNewsStore{}
	p := &Puller{
		Hosts: fakeHostGetter{host: &sshadp.TrackedHost{Name: "relay"}},
		ReadFile: fakeReadFile(map[string]string{
			"/relay/manifest.json": string(manifestBytes),
			"/relay/news.json":     string(newsBytes),
		}),
		Store: store,
		Dir:   dir,
	}

	_, err := p.Pull(context.Background(), "relay", "/relay")
	if err == nil {
		t.Fatal("expected rollback-rejected error, got nil")
	}
	if store.saveCalls != 0 {
		t.Errorf("SaveFeed must not be called on rollback rejection, got %d calls", store.saveCalls)
	}
	cached, ok, _ := readLocalManifest(dir)
	if !ok || cached.Seq != 200 {
		t.Errorf("local manifest cache must stay at the previous snapshot, got ok=%v seq=%d", ok, cached.Seq)
	}
}

func TestPuller_Pull_MissingHostErrorsCleanly(t *testing.T) {
	p := &Puller{
		Hosts: fakeHostGetter{err: errors.New(`host "relay" not tracked`)},
		Store: &fakeNewsStore{},
		Dir:   t.TempDir(),
	}
	_, err := p.Pull(context.Background(), "relay", "/relay")
	if err == nil {
		t.Fatal("expected error for untracked host, got nil")
	}
}

func TestPuller_Pull_RequiresHostAndDir(t *testing.T) {
	p := &Puller{Hosts: fakeHostGetter{}, Store: &fakeNewsStore{}, Dir: t.TempDir()}
	if _, err := p.Pull(context.Background(), "", "/relay"); err == nil {
		t.Error("expected error for empty host")
	}
	if _, err := p.Pull(context.Background(), "relay", ""); err == nil {
		t.Error("expected error for empty dir")
	}
}
