// Package usagelog scans ~/.claude/projects/**/*.jsonl session logs to
// aggregate Claude Code token usage across calendar windows. Same data
// source ccusage (npm) uses; covers both the terminal CLI and the
// VSCode/IDE extension since they share the projects directory.
package usagelog

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// Scanner walks the projects directory and folds assistant-message usage
// blocks into a UsageStatsReport. Files older than maxFileAge are skipped
// (their content is necessarily older than the largest window we report).
type Scanner struct {
	root       string
	maxFileAge time.Duration
	// cachePath persists per-file scan offsets + 15-minute usage totals so
	// each csw process only reads the bytes appended since the last scan.
	// Empty disables persistence (every Scan is a full scan).
	cachePath string
}

// NewScanner returns a scanner rooted at ~/.claude/projects (HOME expansion
// handled by the caller in production; tests inject an explicit root).
func NewScanner(root string) *Scanner {
	return &Scanner{
		root: root,
		// Monthly histogram is the longest window (12 months). 13 months gives
		// a safety margin so an end-of-month file still gets scanned on the 1st.
		maxFileAge: 13 * 31 * 24 * time.Hour,
	}
}

// WithCacheFile enables the persisted incremental scan cache at path.
func (s *Scanner) WithCacheFile(path string) *Scanner {
	s.cachePath = path
	return s
}

// Scan walks the project tree and returns aggregate buckets for the calendar
// Today / ThisWeek (Monday-anchored) / ThisMonth windows in the local zone,
// plus three histogram series (hourly / daily / monthly) for the chart in the
// popover. Errors from individual files are swallowed (best-effort) — a
// corrupt or transiently-locked log should not nuke the whole report.
//
func (s *Scanner) Scan(ctx context.Context, now time.Time) (*domain.UsageStatsReport, error) {
	report := &domain.UsageStatsReport{FetchedAt: now}

	loc := now.Location()
	todayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, loc)
	weekStart := startOfISOWeek(now)
	monthStart := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, loc)
	cutoff := now.Add(-s.maxFileAge)

	hourly := buildHourlySlots(now)
	daily := buildDailySlots(now)
	monthly := buildMonthlySlots(now)
	hourlyEarliest := hourly[0].Start
	dailyEarliest := daily[0].Start
	monthlyEarliest := monthly[0].Start

	if _, err := os.Stat(s.root); errors.Is(err, fs.ErrNotExist) {
		report.Hourly = hourly
		report.Daily = daily
		report.Monthly = monthly
		return report, nil
	}

	cache := loadScanCache(s.cachePath)
	next := &scanCache{Version: scanCacheVersion, Files: make(map[string]*fileState, len(cache.Files))}
	changed := false

	err := filepath.WalkDir(s.root, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if d.IsDir() || !strings.HasSuffix(d.Name(), ".jsonl") {
			return nil
		}
		info, infoErr := d.Info()
		if infoErr != nil {
			return nil
		}
		if info.ModTime().Before(cutoff) {
			return nil
		}
		st := cache.Files[path]
		// New file, or one that shrank below our offset (rewritten) — start over.
		if st == nil || info.Size() < st.Offset {
			st = &fileState{}
			changed = true
		}
		if info.Size() > st.Offset {
			foldNewLines(path, st)
			changed = true
		}
		next.Files[path] = st
		return nil
	})
	// Files that vanished or aged out drop from the cache.
	if len(next.Files) != len(cache.Files) {
		changed = true
	}

	for _, st := range next.Files {
		for _, q := range st.Quarters {
			foldQuarter(q, monthStart, weekStart, todayStart,
				hourly, daily, monthly,
				hourlyEarliest, dailyEarliest, monthlyEarliest,
				report)
		}
	}
	if err == nil && changed {
		// Best-effort: a cache write failure only costs a rescan next time.
		_ = saveScanCache(s.cachePath, next)
	}

	report.Hourly = hourly
	report.Daily = daily
	report.Monthly = monthly
	if err != nil && !errors.Is(err, context.Canceled) {
		return report, err
	}
	return report, nil
}

// buildHourlySlots returns 24 hour-aligned slots ending with the current hour.
func buildHourlySlots(now time.Time) []domain.TimedBucket {
	loc := now.Location()
	current := time.Date(now.Year(), now.Month(), now.Day(), now.Hour(), 0, 0, 0, loc)
	slots := make([]domain.TimedBucket, 24)
	for i := range slots {
		offset := -(23 - i) // oldest first
		slots[i] = domain.TimedBucket{Start: current.Add(time.Duration(offset) * time.Hour)}
	}
	return slots
}

// dailySlotCount is the length of the daily histogram: 182 days (~26 weeks)
// so the popover's calendar-heatmap view can render a full 6-month
// contribution grid. The 13-month maxFileAge already covers this window, so
// widening it costs nothing extra to scan. The Wave chart's "Day" view still
// plots only the last 7 of these.
const dailySlotCount = 182

// buildDailySlots returns dailySlotCount day-aligned slots ending with today.
func buildDailySlots(now time.Time) []domain.TimedBucket {
	loc := now.Location()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, loc)
	slots := make([]domain.TimedBucket, dailySlotCount)
	for i := range slots {
		offset := -(dailySlotCount - 1 - i)
		slots[i] = domain.TimedBucket{Start: today.AddDate(0, 0, offset)}
	}
	return slots
}

// buildMonthlySlots returns 12 month-aligned slots ending with the current month.
func buildMonthlySlots(now time.Time) []domain.TimedBucket {
	loc := now.Location()
	thisMonth := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, loc)
	slots := make([]domain.TimedBucket, 12)
	for i := range slots {
		offset := -(11 - i)
		slots[i] = domain.TimedBucket{Start: thisMonth.AddDate(0, offset, 0)}
	}
	return slots
}

// foldQuarter adds one 15-minute usage slot to the calendar aggregates and
// histogram series. Every window boundary is a local hour edge, which is
// also a quarter edge, so placing the whole slot by its start is exact.
func foldQuarter(
	q usageQuarter,
	monthStart, weekStart, todayStart time.Time,
	hourly, daily, monthly []domain.TimedBucket,
	hourlyEarliest, dailyEarliest, monthlyEarliest time.Time,
	report *domain.UsageStatsReport,
) {
	tsLocal := time.Unix(q[0]*quarterSec, 0).In(monthlyEarliest.Location())
	if tsLocal.Before(monthlyEarliest) {
		return
	}
	// Calendar aggregates: current month / week / day in local time.
	if !tsLocal.Before(monthStart) {
		addQuarter(&report.ThisMonth, q)
	}
	if !tsLocal.Before(weekStart) {
		addQuarter(&report.ThisWeek, q)
	}
	if !tsLocal.Before(todayStart) {
		addQuarter(&report.Today, q)
	}

	// Histogram series.
	if !tsLocal.Before(hourlyEarliest) {
		idx := int(tsLocal.Sub(hourlyEarliest) / time.Hour)
		if idx >= 0 && idx < len(hourly) {
			addQuarter(&hourly[idx].Bucket, q)
		}
	}
	if !tsLocal.Before(dailyEarliest) {
		idx := int(tsLocal.Sub(dailyEarliest) / (24 * time.Hour))
		if idx >= 0 && idx < len(daily) {
			addQuarter(&daily[idx].Bucket, q)
		}
	}
	idx := monthDiff(monthlyEarliest, tsLocal)
	if idx >= 0 && idx < len(monthly) {
		addQuarter(&monthly[idx].Bucket, q)
	}
}

// monthDiff returns the index of `t` in a series of month-aligned slots that
// begins at `start`. Years and months are accounted for; day-of-month is
// ignored (slots are month-aligned anyway).
func monthDiff(start, t time.Time) int {
	years := t.Year() - start.Year()
	months := int(t.Month()) - int(start.Month())
	return years*12 + months
}

type assistantLogEntry struct {
	Type      string `json:"type"`
	Timestamp string `json:"timestamp"`
	Message   struct {
		Model string      `json:"model"`
		Usage *usageBlock `json:"usage,omitempty"`
	} `json:"message"`
}

// usageBlock mirrors Anthropic's per-message usage payload. Fields not used
// downstream (server_tool_use, service_tier, iterations…) are ignored.
type usageBlock struct {
	InputTokens   int64 `json:"input_tokens"`
	OutputTokens  int64 `json:"output_tokens"`
	CacheCreation int64 `json:"cache_creation_input_tokens"`
	CacheRead     int64 `json:"cache_read_input_tokens"`
}

// startOfISOWeek returns Monday 00:00 in the receiver's location.
// ISO calendar: Monday = day 1. Go's time.Weekday() returns Sunday = 0,
// so an explicit table is simpler than arithmetic.
func startOfISOWeek(now time.Time) time.Time {
	loc := now.Location()
	daysBack := map[time.Weekday]int{
		time.Monday:    0,
		time.Tuesday:   1,
		time.Wednesday: 2,
		time.Thursday:  3,
		time.Friday:    4,
		time.Saturday:  5,
		time.Sunday:    6,
	}[now.Weekday()]
	d := now.AddDate(0, 0, -daysBack)
	return time.Date(d.Year(), d.Month(), d.Day(), 0, 0, 0, 0, loc)
}
