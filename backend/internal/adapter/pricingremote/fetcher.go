// Package pricingremote fetches Anthropic's per-model rate table from a
// hosted JSON file (default: raw.githubusercontent.com/<repo>/main/pricing.json)
// so existing builds pick up price changes without a new release.
//
// Lifecycle:
//   - On construction, the provider bootstraps from the bundled
//     domain.PublishedPricing() so Current() never returns nil even before
//     the first network call.
//   - It then loads any disk cache (last successful fetch) to surface the
//     freshest known snapshot.
//   - Refresh(ctx) kicks off a background HTTP GET. The result is validated,
//     swapped into the atomic snapshot, and written to disk. Failures keep
//     the existing snapshot — there is no "blank slate" state.
//
// Validation is intentionally strict: a malformed or out-of-range JSON file
// is ignored rather than allowed to poison the cost column.
package pricingremote

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// DefaultURL is the hosted pricing.json on the main branch. Stable raw.github
// URL so we do not need GitHub Pages set up.
const DefaultURL = "https://raw.githubusercontent.com/ncthanhngo/claude-bar/main/pricing.json"

// DefaultRefreshTTL is the minimum gap between successive HTTP fetches.
// Anthropic adjusts rates very rarely; a once-a-day refresh is plenty.
const DefaultRefreshTTL = 24 * time.Hour

// DefaultHTTPTimeout caps each fetch. Short enough that a slow network does
// not stall startup; the provider always has a usable bundled snapshot.
const DefaultHTTPTimeout = 6 * time.Second

// Provider implements port.PricingProvider.
type Provider struct {
	url        string
	cachePath  string
	httpClient *http.Client
	refreshTTL time.Duration

	current atomic.Pointer[snapshot]

	mu            sync.Mutex // guards lastAttempt + inflight
	lastAttempt   time.Time
	inflight      bool
}

type snapshot struct {
	rates     []domain.ModelPricing
	reference string
}

// hostedFile is the JSON shape served at the hosted URL.
type hostedFile struct {
	Schema    string                `json:"$schema"`
	Reference string                `json:"reference"`
	Rates     []domain.ModelPricing `json:"rates"`
}

const expectedSchema = "claude-bar-pricing-v1"

// New returns a provider bootstrapped from the bundled rates + (best-effort)
// disk cache. Does NOT block on the network; the caller should invoke
// Refresh(ctx) once at startup if a fresh snapshot is desired.
//
// url defaults to DefaultURL if empty; cachePath should be the path returned
// by adapter.PricingCacheFile().
func New(url, cachePath string) *Provider {
	if url == "" {
		url = DefaultURL
	}
	p := &Provider{
		url:        url,
		cachePath:  cachePath,
		httpClient: &http.Client{Timeout: DefaultHTTPTimeout},
		refreshTTL: DefaultRefreshTTL,
	}
	// Bootstrap from bundled so Current() is never nil.
	p.current.Store(&snapshot{
		rates:     domain.PublishedPricing(),
		reference: domain.PublishedPricingReference,
	})
	// Promote disk cache if present + valid — gives us the freshest known
	// snapshot before the first network refresh lands.
	if snap, err := p.loadDiskCache(); err == nil {
		p.current.Store(snap)
	}
	return p
}

// Current returns the active snapshot. Never blocks. Never returns nil.
func (p *Provider) Current() ([]domain.ModelPricing, string) {
	s := p.current.Load()
	return s.rates, s.reference
}

// Refresh kicks off a background HTTP fetch. Multiple concurrent Refresh
// calls collapse into a single in-flight fetch; calls within refreshTTL of
// the previous attempt are no-ops.
func (p *Provider) Refresh(ctx context.Context) {
	p.mu.Lock()
	if p.inflight || time.Since(p.lastAttempt) < p.refreshTTL {
		p.mu.Unlock()
		return
	}
	p.inflight = true
	p.lastAttempt = time.Now()
	p.mu.Unlock()

	go func() {
		defer func() {
			p.mu.Lock()
			p.inflight = false
			p.mu.Unlock()
		}()
		if err := p.fetchAndSwap(ctx); err != nil {
			log.Printf("[pricingremote] fetch failed (keeping cached snapshot): %v", err)
		}
	}()
}

// SetRefreshTTL is for tests that want to force back-to-back fetches.
func (p *Provider) SetRefreshTTL(d time.Duration) {
	p.mu.Lock()
	p.refreshTTL = d
	p.mu.Unlock()
}

func (p *Provider) fetchAndSwap(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.url, nil)
	if err != nil {
		return fmt.Errorf("building request: %w", err)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := p.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("get %s: %w", p.url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("got HTTP %d from %s", resp.StatusCode, p.url)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		return fmt.Errorf("reading body: %w", err)
	}

	snap, err := parseHostedJSON(body)
	if err != nil {
		return fmt.Errorf("validating payload: %w", err)
	}

	p.current.Store(snap)
	// Best-effort disk persist — failure to cache should not abort the swap.
	if p.cachePath != "" {
		if err := p.writeDiskCache(body); err != nil {
			log.Printf("[pricingremote] disk cache write failed: %v", err)
		}
	}
	return nil
}

func (p *Provider) loadDiskCache() (*snapshot, error) {
	if p.cachePath == "" {
		return nil, errors.New("no cache path configured")
	}
	body, err := os.ReadFile(p.cachePath)
	if err != nil {
		return nil, err
	}
	return parseHostedJSON(body)
}

func (p *Provider) writeDiskCache(body []byte) error {
	if err := os.MkdirAll(filepath.Dir(p.cachePath), 0o700); err != nil {
		return err
	}
	tmp := p.cachePath + ".tmp"
	if err := os.WriteFile(tmp, body, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, p.cachePath)
}

// parseHostedJSON enforces the schema + sane bounds. Returns a snapshot or
// a descriptive error — callers log and keep the existing snapshot on err.
func parseHostedJSON(body []byte) (*snapshot, error) {
	var f hostedFile
	if err := json.Unmarshal(body, &f); err != nil {
		return nil, fmt.Errorf("json: %w", err)
	}
	if f.Schema != expectedSchema {
		return nil, fmt.Errorf("schema %q != expected %q", f.Schema, expectedSchema)
	}
	if strings.TrimSpace(f.Reference) == "" {
		return nil, errors.New("reference is empty")
	}
	if len(f.Rates) == 0 {
		return nil, errors.New("rates array is empty")
	}
	for _, r := range f.Rates {
		if strings.TrimSpace(r.Family) == "" {
			return nil, errors.New("rate row missing family")
		}
		// Sanity bounds. Anthropic rates are USD/1M tokens, currently $0.08–$75.
		// 0 is allowed (a tier might be free), $10k is well beyond any plausible
		// future rate — anything past it is almost certainly a typo or unit
		// confusion (e.g. someone wrote per-1k instead of per-1M).
		for _, v := range [...]float64{r.Input, r.Output, r.CacheWrite, r.CacheRead} {
			if v < 0 || v > 10000 {
				return nil, fmt.Errorf("rate out of range for %q: %v", r.Family, v)
			}
		}
	}
	return &snapshot{rates: f.Rates, reference: f.Reference}, nil
}
