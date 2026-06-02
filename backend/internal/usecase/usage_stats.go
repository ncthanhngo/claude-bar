package usecase

import (
	"context"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// UsageStats returns calendar-window aggregates of Claude Code token usage
// scraped from the local JSONL session logs. The widget polls this every
// refresh tick — to keep that cheap we cache the report for
// UsageStatsCacheTTL and only re-scan when (a) the cache has aged past TTL
// or (b) the current hour slot has rolled over (which would shift every
// histogram series and the Today/Week/Month calendar buckets).
func (s *Service) UsageStats(ctx context.Context) (*domain.UsageStatsReport, error) {
	now := time.Now()

	s.usageStatsMu.Lock()
	if cached := s.usageStatsCached; cached != nil &&
		time.Since(s.usageStatsCachedAt) < UsageStatsCacheTTL &&
		sameHourSlot(now, s.usageStatsCachedAt) {
		s.usageStatsMu.Unlock()
		return cached, nil
	}
	s.usageStatsMu.Unlock()

	report, err := s.UsageLog.Scan(ctx, now)
	if err != nil {
		return nil, err
	}
	// Pricing/cost are no longer computed (subscription accounts don't pay per
	// token). Ship an EMPTY (non-nil) rate table so the JSON encodes as `[]`,
	// not `null` — the widget's `pricing: [ModelPricingDTO]` is non-optional
	// and a null would fail to decode the whole report.
	report.Pricing = []domain.ModelPricing{}
	report.PricingReference = ""

	s.usageStatsMu.Lock()
	s.usageStatsCached = report
	s.usageStatsCachedAt = now
	s.usageStatsMu.Unlock()
	return report, nil
}

// InvalidateUsageStatsCache drops the cached report so the next call rescans
// the projects directory immediately. Intended for explicit "refresh now"
// surfaces (e.g. a future widget toolbar button); not used internally yet.
func (s *Service) InvalidateUsageStatsCache() {
	s.usageStatsMu.Lock()
	s.usageStatsCached = nil
	s.usageStatsCachedAt = time.Time{}
	s.usageStatsMu.Unlock()
}

// sameHourSlot returns true when a and b fall in the same calendar hour.
// Hour granularity is the finest histogram slot we serve — if a and b are
// in different hours, at least one series boundary has shifted and the
// cache must not be served.
func sameHourSlot(a, b time.Time) bool {
	if a.Location() != b.Location() {
		b = b.In(a.Location())
	}
	return a.Year() == b.Year() && a.YearDay() == b.YearDay() && a.Hour() == b.Hour()
}

