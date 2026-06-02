package usagelog

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// writeJSONL writes a single JSONL file with the given lines (each line is a
// raw JSON string). Returns the file path.
func writeJSONL(t *testing.T, dir, name string, lines []string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	path := filepath.Join(dir, name)
	body := ""
	for _, l := range lines {
		body += l + "\n"
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	return path
}

// assistantLine formats an assistant log entry with the given timestamp + usage.
func assistantLine(ts time.Time, input, output, cacheCreate, cacheRead int64) string {
	return assistantLineWithModel(ts, "claude-opus-4-7", input, output, cacheCreate, cacheRead)
}

func assistantLineWithModel(ts time.Time, model string, input, output, cacheCreate, cacheRead int64) string {
	return fmt.Sprintf(
		`{"type":"assistant","timestamp":"%s","message":{"model":"%s","usage":{"input_tokens":%d,"output_tokens":%d,"cache_creation_input_tokens":%d,"cache_read_input_tokens":%d}}}`,
		ts.UTC().Format(time.RFC3339), model, input, output, cacheCreate, cacheRead,
	)
}

func TestScanner_BucketsByCalendarWindow(t *testing.T) {
	now := time.Date(2026, 5, 22, 14, 0, 0, 0, time.UTC) // Friday
	root := t.TempDir()
	projectDir := filepath.Join(root, "myproject")

	// Today (within this week, within this month)
	todayTs := time.Date(2026, 5, 22, 10, 0, 0, 0, time.UTC)
	// Earlier this week (Monday)
	weekTs := time.Date(2026, 5, 18, 10, 0, 0, 0, time.UTC)
	// Earlier this month (May 5 — before this ISO week)
	monthTs := time.Date(2026, 5, 5, 10, 0, 0, 0, time.UTC)
	// Last month — must be excluded
	pastTs := time.Date(2026, 4, 15, 10, 0, 0, 0, time.UTC)

	writeJSONL(t, projectDir, "s.jsonl", []string{
		assistantLine(todayTs, 100, 50, 200, 1000),
		assistantLine(weekTs, 10, 5, 20, 100),
		assistantLine(monthTs, 1, 2, 3, 4),
		assistantLine(pastTs, 999, 999, 999, 999),
	})

	r, err := NewScanner(root).Scan(context.Background(), now)
	if err != nil {
		t.Fatalf("Scan error: %v", err)
	}

	// Today bucket = only the today line.
	if r.Today.Requests != 1 || r.Today.InputTokens != 100 || r.Today.OutputTokens != 50 {
		t.Fatalf("Today bucket = %+v, want one request 100/50", r.Today)
	}
	// TotalTokens excludes cache reads on purpose (see UsageBucket doc).
	if r.Today.TotalTokens != 100+50+200 {
		t.Fatalf("Today.TotalTokens = %d, want %d (input+output+cache_write, NO cache_read)",
			r.Today.TotalTokens, 100+50+200)
	}
	if r.Today.CacheReadTokens != 1000 {
		t.Fatalf("Today.CacheReadTokens = %d, want 1000", r.Today.CacheReadTokens)
	}

	// Week bucket = today + week.
	if r.ThisWeek.Requests != 2 || r.ThisWeek.InputTokens != 110 {
		t.Fatalf("ThisWeek bucket = %+v, want 2 requests", r.ThisWeek)
	}

	// Month bucket = today + week + earlier-this-month.
	if r.ThisMonth.Requests != 3 || r.ThisMonth.InputTokens != 111 {
		t.Fatalf("ThisMonth bucket = %+v, want 3 requests", r.ThisMonth)
	}

	// Past-month line must be excluded from every bucket.
	if r.ThisMonth.InputTokens > 1000 {
		t.Fatalf("past-month line leaked into ThisMonth: %+v", r.ThisMonth)
	}
}

func TestScanner_SkipsNonAssistantAndMalformed(t *testing.T) {
	now := time.Date(2026, 5, 22, 14, 0, 0, 0, time.UTC)
	root := t.TempDir()
	projectDir := filepath.Join(root, "p")

	todayTs := time.Date(2026, 5, 22, 10, 0, 0, 0, time.UTC)
	writeJSONL(t, projectDir, "s.jsonl", []string{
		// user message — must be skipped
		fmt.Sprintf(`{"type":"user","timestamp":"%s","message":{"role":"user"}}`, todayTs.Format(time.RFC3339)),
		// queue-operation — must be skipped
		fmt.Sprintf(`{"type":"queue-operation","timestamp":"%s"}`, todayTs.Format(time.RFC3339)),
		// malformed JSON — must be skipped (not panic)
		`{not json}`,
		// assistant but no usage — must be skipped
		fmt.Sprintf(`{"type":"assistant","timestamp":"%s","message":{}}`, todayTs.Format(time.RFC3339)),
		// valid assistant — the only one that counts
		assistantLine(todayTs, 5, 7, 0, 0),
	})

	r, err := NewScanner(root).Scan(context.Background(), now)
	if err != nil {
		t.Fatalf("Scan error: %v", err)
	}
	if r.Today.Requests != 1 || r.Today.InputTokens != 5 || r.Today.OutputTokens != 7 {
		t.Fatalf("Today bucket = %+v, want one valid assistant 5/7", r.Today)
	}
}

func TestScanner_RootMissing_ReturnsEmptyReport(t *testing.T) {
	now := time.Now()
	root := filepath.Join(t.TempDir(), "does-not-exist")
	r, err := NewScanner(root).Scan(context.Background(), now)
	if err != nil {
		t.Fatalf("Scan error: %v", err)
	}
	if r.Today.Requests != 0 || r.ThisWeek.Requests != 0 || r.ThisMonth.Requests != 0 {
		t.Fatalf("buckets should be empty: %+v", r)
	}
}

func TestScanner_SkipsFilesOlderThanMaxAge(t *testing.T) {
	now := time.Now()
	root := t.TempDir()
	projectDir := filepath.Join(root, "p")

	// Backdate the file's mtime to 90 days ago — should be skipped entirely
	// even if its timestamp lines were recent.
	todayTs := time.Now().Add(-1 * time.Hour) // recent line
	path := writeJSONL(t, projectDir, "old.jsonl", []string{
		assistantLine(todayTs, 1000, 1000, 1000, 1000),
	})
	// Cutoff is ~13 months (longest histogram window). Pick a date safely past
	// that so the file is unambiguously excluded.
	old := time.Now().AddDate(-2, 0, 0)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	r, err := NewScanner(root).Scan(context.Background(), now)
	if err != nil {
		t.Fatalf("Scan error: %v", err)
	}
	if r.Today.Requests != 0 {
		t.Fatalf("old file should have been skipped by mtime: %+v", r.Today)
	}
}

func TestScanner_BuildsHistogramSeriesWithFixedLengths(t *testing.T) {
	now := time.Date(2026, 5, 22, 14, 0, 0, 0, time.UTC)
	root := t.TempDir()
	projectDir := filepath.Join(root, "p")

	// now = 14:00. Hour slots are [Start, Start+1h). The current hour bucket
	// at index 23 has Start=14:00, which only accepts ts >= 14:00 — a line at
	// 13:50 lands in slot 22 (Start=13:00) instead.
	prevHour := now.Add(-10 * time.Minute)   // 13:50 → slot 22
	threeHoursAgo := now.Add(-3 * time.Hour) // 11:00 → slot 20
	fiveDaysAgo := now.AddDate(0, 0, -5)     // 5 days back → daily slot 24
	writeJSONL(t, projectDir, "s.jsonl", []string{
		assistantLine(prevHour, 10, 20, 30, 40),
		assistantLine(threeHoursAgo, 1, 2, 3, 4),
		assistantLine(fiveDaysAgo, 100, 200, 300, 400),
	})

	r, err := NewScanner(root).Scan(context.Background(), now)
	if err != nil {
		t.Fatalf("Scan error: %v", err)
	}

	if len(r.Hourly) != 24 || len(r.Daily) != 30 || len(r.Monthly) != 12 {
		t.Fatalf("series lengths = %d/%d/%d, want 24/30/12",
			len(r.Hourly), len(r.Daily), len(r.Monthly))
	}

	if r.Hourly[22].Bucket.Requests != 1 || r.Hourly[22].Bucket.InputTokens != 10 {
		t.Fatalf("Hourly[22] = %+v, want one request 10/20 from 13:50 line", r.Hourly[22])
	}
	if r.Hourly[20].Bucket.Requests != 1 || r.Hourly[20].Bucket.InputTokens != 1 {
		t.Fatalf("Hourly[20] = %+v, want one request 1/2 from 11:00 line", r.Hourly[20])
	}
	// Daily slot 24 = 5 days back (today is slot 29).
	if r.Daily[24].Bucket.Requests != 1 || r.Daily[24].Bucket.InputTokens != 100 {
		t.Fatalf("Daily[24] = %+v, want one request 100/200", r.Daily[24])
	}
	// Monthly final slot (idx 11) carries all three lines (all in current month).
	if r.Monthly[11].Bucket.Requests != 3 {
		t.Fatalf("Monthly[11] = %+v, want 3 requests in current month", r.Monthly[11])
	}
}

func TestStartOfISOWeek_AnchorsToMonday(t *testing.T) {
	loc := time.UTC
	cases := []struct {
		in   time.Time
		want time.Time
	}{
		// Wednesday → Monday
		{
			in:   time.Date(2026, 5, 20, 15, 0, 0, 0, loc),
			want: time.Date(2026, 5, 18, 0, 0, 0, 0, loc),
		},
		// Sunday → previous Monday (6 days back)
		{
			in:   time.Date(2026, 5, 24, 23, 0, 0, 0, loc),
			want: time.Date(2026, 5, 18, 0, 0, 0, 0, loc),
		},
		// Monday → same day at 00:00
		{
			in:   time.Date(2026, 5, 18, 14, 30, 0, 0, loc),
			want: time.Date(2026, 5, 18, 0, 0, 0, 0, loc),
		},
	}
	for _, c := range cases {
		got := startOfISOWeek(c.in)
		if !got.Equal(c.want) {
			t.Errorf("startOfISOWeek(%v) = %v, want %v", c.in, got, c.want)
		}
	}
}
