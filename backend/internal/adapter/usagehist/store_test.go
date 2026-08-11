package usagehist

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

func monthBucket(total int64) domain.UsageBucket {
	return domain.UsageBucket{TotalTokens: total, Requests: 1}
}

func report(months map[string]int64) *domain.UsageStatsReport {
	r := &domain.UsageStatsReport{}
	// Deterministic order: Jul then Aug 2026.
	for _, ym := range []struct {
		key string
		t   time.Time
	}{
		{"2026-07", time.Date(2026, 7, 1, 0, 0, 0, 0, time.Local)},
		{"2026-08", time.Date(2026, 8, 1, 0, 0, 0, 0, time.Local)},
	} {
		r.Monthly = append(r.Monthly, domain.TimedBucket{
			Start:  ym.t,
			Bucket: monthBucket(months[ym.key]),
		})
	}
	return r
}

// A completed month's total must survive a later scan that lost its logs to
// pruning (live drops to 0), while the current month keeps growing.
func TestMergeBackfillsPrunedMonth(t *testing.T) {
	s := newStoreAt(filepath.Join(t.TempDir(), "monthly-history.json"))

	// First scan: Jul=100, Aug=50 both present.
	r1 := report(map[string]int64{"2026-07": 100, "2026-08": 50})
	if err := s.Merge(r1); err != nil {
		t.Fatalf("first merge: %v", err)
	}

	// Second scan: Jul pruned to 0, Aug grew to 80.
	r2 := report(map[string]int64{"2026-07": 0, "2026-08": 80})
	if err := s.Merge(r2); err != nil {
		t.Fatalf("second merge: %v", err)
	}

	if got := r2.Monthly[0].Bucket.TotalTokens; got != 100 {
		t.Errorf("Jul backfill: got %d, want 100 (history should survive pruning)", got)
	}
	if got := r2.Monthly[1].Bucket.TotalTokens; got != 80 {
		t.Errorf("Aug: got %d, want 80 (current month should grow)", got)
	}
}

// A missing history file yields the live report unchanged, and no zero months
// are persisted.
func TestMergeEmptyMonthsNotPersisted(t *testing.T) {
	path := filepath.Join(t.TempDir(), "monthly-history.json")
	s := newStoreAt(path)

	r := report(map[string]int64{"2026-07": 0, "2026-08": 0})
	if err := s.Merge(r); err != nil {
		t.Fatalf("merge: %v", err)
	}

	m, err := s.load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(m) != 0 {
		t.Errorf("expected no persisted months for all-zero report, got %d", len(m))
	}
}
