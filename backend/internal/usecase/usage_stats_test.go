package usecase

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

type usageStatsCountingScanner struct {
	calls int32
}

func (s *usageStatsCountingScanner) Scan(_ context.Context, now time.Time, _ []domain.ModelPricing) (*domain.UsageStatsReport, error) {
	atomic.AddInt32(&s.calls, 1)
	return &domain.UsageStatsReport{FetchedAt: now}, nil
}

func TestUsageStats_CachesWithinTTL(t *testing.T) {
	scanner := &usageStatsCountingScanner{}
	svc := &Service{UsageLog: scanner}

	for i := 0; i < 3; i++ {
		if _, err := svc.UsageStats(context.Background()); err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
	}
	if scanner.calls != 1 {
		t.Fatalf("scanner.calls = %d, want 1 (subsequent reads should be served from cache)", scanner.calls)
	}
}

func TestUsageStats_InvalidateForcesRescan(t *testing.T) {
	scanner := &usageStatsCountingScanner{}
	svc := &Service{UsageLog: scanner}

	if _, err := svc.UsageStats(context.Background()); err != nil {
		t.Fatal(err)
	}
	svc.InvalidateUsageStatsCache()
	if _, err := svc.UsageStats(context.Background()); err != nil {
		t.Fatal(err)
	}
	if scanner.calls != 2 {
		t.Fatalf("scanner.calls = %d, want 2 after explicit invalidation", scanner.calls)
	}
}

func TestUsageStats_ExpiresAfterTTL(t *testing.T) {
	scanner := &usageStatsCountingScanner{}
	svc := &Service{UsageLog: scanner}

	if _, err := svc.UsageStats(context.Background()); err != nil {
		t.Fatal(err)
	}
	// Backdate the cache timestamp past TTL — simulates time having moved on
	// without actually sleeping in the test.
	svc.usageStatsMu.Lock()
	svc.usageStatsCachedAt = time.Now().Add(-(UsageStatsCacheTTL + time.Minute))
	svc.usageStatsMu.Unlock()

	if _, err := svc.UsageStats(context.Background()); err != nil {
		t.Fatal(err)
	}
	if scanner.calls != 2 {
		t.Fatalf("scanner.calls = %d, want 2 after TTL expiry", scanner.calls)
	}
}

func TestUsageStats_HourRolloverForcesRescan(t *testing.T) {
	scanner := &usageStatsCountingScanner{}
	svc := &Service{UsageLog: scanner}

	if _, err := svc.UsageStats(context.Background()); err != nil {
		t.Fatal(err)
	}
	// Backdate one hour — same wall clock TTL window, but a different hour slot.
	// All three histogram series would have shifted, so the cache MUST drop.
	svc.usageStatsMu.Lock()
	svc.usageStatsCachedAt = time.Now().Add(-90 * time.Minute)
	svc.usageStatsMu.Unlock()

	if _, err := svc.UsageStats(context.Background()); err != nil {
		t.Fatal(err)
	}
	if scanner.calls != 2 {
		t.Fatalf("scanner.calls = %d, want 2 after hour rollover", scanner.calls)
	}
}

type fakePricingProvider struct {
	rates     []domain.ModelPricing
	reference string
}

func (f *fakePricingProvider) Current() ([]domain.ModelPricing, string) {
	return f.rates, f.reference
}
func (f *fakePricingProvider) Refresh(_ context.Context) {}

func TestUsageStats_RescansWhenPricingReferenceChanges(t *testing.T) {
	scanner := &usageStatsCountingScanner{}
	provider := &fakePricingProvider{
		rates:     domain.PublishedPricing(),
		reference: "snapshot A",
	}
	svc := &Service{UsageLog: scanner, Pricing: provider}

	if _, err := svc.UsageStats(context.Background()); err != nil {
		t.Fatal(err)
	}
	// Provider swaps to a new pricing snapshot (e.g. background refresh
	// picked up an updated hosted JSON). Cache must drop so cost recomputes.
	provider.reference = "snapshot B"
	if _, err := svc.UsageStats(context.Background()); err != nil {
		t.Fatal(err)
	}
	if scanner.calls != 2 {
		t.Fatalf("scanner.calls = %d, want 2 after pricing-reference shift", scanner.calls)
	}
}

func TestSameHourSlot(t *testing.T) {
	loc := time.UTC
	a := time.Date(2026, 5, 22, 14, 0, 0, 0, loc)
	b := time.Date(2026, 5, 22, 14, 59, 59, 0, loc)
	if !sameHourSlot(a, b) {
		t.Errorf("14:00:00 and 14:59:59 should be the same hour slot")
	}
	c := time.Date(2026, 5, 22, 15, 0, 0, 0, loc)
	if sameHourSlot(a, c) {
		t.Errorf("14:00 and 15:00 should be different hour slots")
	}
	// Day rollover within same hour-of-day → different slots.
	d := time.Date(2026, 5, 23, 14, 0, 0, 0, loc)
	if sameHourSlot(a, d) {
		t.Errorf("two days both at 14:00 must be different slots")
	}
}
