package pricingremote

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

const validJSON = `{
  "$schema": "claude-bar-pricing-v1",
  "reference": "test rates 2099",
  "rates": [
    {"family": "opus",   "input": 99.0, "output": 99.0, "cacheWrite": 99.0, "cacheRead": 99.0},
    {"family": "sonnet", "input": 1.0,  "output": 1.0,  "cacheWrite": 1.0,  "cacheRead": 1.0}
  ]
}`

// New() bootstraps from bundled, so Current() must be usable before any
// network call. Real cold-start behaviour.
func TestProvider_BootstrapsFromBundledBeforeNetwork(t *testing.T) {
	p := New("http://invalid.invalid/never-resolves", filepath.Join(t.TempDir(), "p.json"))
	rates, ref := p.Current()
	if len(rates) == 0 {
		t.Fatal("Current() returned empty rates before refresh")
	}
	if ref != domain.PublishedPricingReference {
		t.Fatalf("expected bundled reference, got %q", ref)
	}
}

func TestProvider_RefreshSwapsToHostedSnapshot(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(validJSON))
	}))
	defer srv.Close()

	cache := filepath.Join(t.TempDir(), "p.json")
	p := New(srv.URL, cache)
	p.SetRefreshTTL(time.Millisecond) // bypass debounce
	p.Refresh(context.Background())

	if !waitForReference(p, "test rates 2099", 2*time.Second) {
		_, ref := p.Current()
		t.Fatalf("never picked up hosted snapshot, current reference: %q", ref)
	}
	if _, err := os.Stat(cache); err != nil {
		t.Fatalf("expected disk cache at %s, got %v", cache, err)
	}
}

func TestProvider_KeepsCachedSnapshotOnFetchFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()

	p := New(srv.URL, filepath.Join(t.TempDir(), "p.json"))
	p.SetRefreshTTL(time.Millisecond)
	p.Refresh(context.Background())

	// Give the goroutine a chance to fail.
	time.Sleep(150 * time.Millisecond)

	_, ref := p.Current()
	if ref != domain.PublishedPricingReference {
		t.Fatalf("snapshot moved off bundled after failed fetch: %q", ref)
	}
}

func TestProvider_LoadsDiskCacheOnConstruction(t *testing.T) {
	dir := t.TempDir()
	cache := filepath.Join(dir, "p.json")
	if err := os.WriteFile(cache, []byte(validJSON), 0o600); err != nil {
		t.Fatal(err)
	}
	p := New("http://invalid.invalid/never-resolves", cache)
	_, ref := p.Current()
	if ref != "test rates 2099" {
		t.Fatalf("expected disk-cached reference, got %q", ref)
	}
}

func TestProvider_RejectsWrongSchema(t *testing.T) {
	body := []byte(`{"$schema":"some-other-thing","reference":"x","rates":[{"family":"opus","input":1,"output":1,"cacheWrite":1,"cacheRead":1}]}`)
	if _, err := parseHostedJSON(body); err == nil {
		t.Fatal("expected schema mismatch error, got nil")
	}
}

func TestProvider_RejectsOutOfRangeRate(t *testing.T) {
	// $9999 is fine, but $50,000 is well past plausible — typically means
	// someone mixed per-1k with per-1M. Provider must reject rather than
	// poison the cost column.
	body := []byte(`{"$schema":"claude-bar-pricing-v1","reference":"x","rates":[{"family":"opus","input":50000,"output":1,"cacheWrite":1,"cacheRead":1}]}`)
	if _, err := parseHostedJSON(body); err == nil {
		t.Fatal("expected range error for $50,000 rate")
	}
}

func TestProvider_RefreshDebouncesByTTL(t *testing.T) {
	hits := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits++
		_, _ = w.Write([]byte(validJSON))
	}))
	defer srv.Close()

	p := New(srv.URL, filepath.Join(t.TempDir(), "p.json"))
	// Long TTL: only the first Refresh should actually fetch.
	p.SetRefreshTTL(time.Hour)

	p.Refresh(context.Background())
	waitForReference(p, "test rates 2099", time.Second)

	// Reset the inflight gate and try again — TTL must still block it.
	p.Refresh(context.Background())
	time.Sleep(100 * time.Millisecond)

	if hits != 1 {
		t.Fatalf("expected 1 fetch despite 2 Refresh calls, got %d", hits)
	}
}

// waitForReference polls Current().reference up to timeout. Returns true
// once the reference matches. Background goroutine -> need polling, not a
// channel (the production API does not expose one).
func waitForReference(p *Provider, want string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, ref := p.Current(); ref == want {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}
