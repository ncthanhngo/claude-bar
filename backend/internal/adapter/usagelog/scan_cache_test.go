package usagelog

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func appendToFile(t *testing.T, path, body string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer f.Close()
	if _, err := f.WriteString(body); err != nil {
		t.Fatalf("append: %v", err)
	}
}

func cachedScanner(t *testing.T, root string) *Scanner {
	return NewScanner(root).WithCacheFile(filepath.Join(t.TempDir(), "scan-cache.json"))
}

func TestScanCache_AppendedLinesCountedExactlyOnce(t *testing.T) {
	now := time.Date(2026, 5, 22, 14, 0, 0, 0, time.UTC)
	root := t.TempDir()
	ts := time.Date(2026, 5, 22, 10, 5, 0, 0, time.UTC)
	path := writeJSONL(t, root, "s.jsonl", []string{
		assistantLine(ts, 100, 0, 0, 0),
		assistantLine(ts.Add(time.Minute), 10, 0, 0, 0), // same 15-min slot
	})
	s := cachedScanner(t, root)

	r, err := s.Scan(context.Background(), now)
	if err != nil {
		t.Fatal(err)
	}
	if r.Today.Requests != 2 || r.Today.InputTokens != 110 {
		t.Fatalf("first scan Today = %+v, want 2 requests / 110 input", r.Today)
	}

	appendToFile(t, path, assistantLine(ts.Add(2*time.Minute), 1, 0, 0, 0)+"\n")
	for i := 0; i < 2; i++ { // second pass re-reads nothing new
		r, err = s.Scan(context.Background(), now)
		if err != nil {
			t.Fatal(err)
		}
		if r.Today.Requests != 3 || r.Today.InputTokens != 111 {
			t.Fatalf("scan %d Today = %+v, want 3 requests / 111 input", i+2, r.Today)
		}
	}
}

func TestScanCache_PartialTrailingLineWaitsForNewline(t *testing.T) {
	now := time.Date(2026, 5, 22, 14, 0, 0, 0, time.UTC)
	root := t.TempDir()
	ts := time.Date(2026, 5, 22, 10, 0, 0, 0, time.UTC)
	path := writeJSONL(t, root, "s.jsonl", []string{assistantLine(ts, 100, 0, 0, 0)})
	line := assistantLine(ts, 7, 0, 0, 0)
	appendToFile(t, path, line[:20]) // writer mid-flush
	s := cachedScanner(t, root)

	r, _ := s.Scan(context.Background(), now)
	if r.Today.InputTokens != 100 {
		t.Fatalf("partial line counted: Today = %+v", r.Today)
	}
	appendToFile(t, path, line[20:]+"\n")
	r, _ = s.Scan(context.Background(), now)
	if r.Today.Requests != 2 || r.Today.InputTokens != 107 {
		t.Fatalf("completed line not counted once: Today = %+v", r.Today)
	}
}

func TestScanCache_RewrittenShorterFileRescans(t *testing.T) {
	now := time.Date(2026, 5, 22, 14, 0, 0, 0, time.UTC)
	root := t.TempDir()
	ts := time.Date(2026, 5, 22, 10, 0, 0, 0, time.UTC)
	writeJSONL(t, root, "s.jsonl", []string{
		assistantLine(ts, 100, 0, 0, 0),
		assistantLine(ts, 200, 0, 0, 0),
	})
	s := cachedScanner(t, root)
	if _, err := s.Scan(context.Background(), now); err != nil {
		t.Fatal(err)
	}

	writeJSONL(t, root, "s.jsonl", []string{assistantLine(ts, 5, 0, 0, 0)})
	r, _ := s.Scan(context.Background(), now)
	if r.Today.Requests != 1 || r.Today.InputTokens != 5 {
		t.Fatalf("rewritten file: Today = %+v, want only the new content", r.Today)
	}
}

func TestScanCache_DeletedFileDropsOut(t *testing.T) {
	now := time.Date(2026, 5, 22, 14, 0, 0, 0, time.UTC)
	root := t.TempDir()
	ts := time.Date(2026, 5, 22, 10, 0, 0, 0, time.UTC)
	writeJSONL(t, root, "keep.jsonl", []string{assistantLine(ts, 1, 0, 0, 0)})
	gone := writeJSONL(t, root, "gone.jsonl", []string{assistantLine(ts, 100, 0, 0, 0)})
	s := cachedScanner(t, root)
	if _, err := s.Scan(context.Background(), now); err != nil {
		t.Fatal(err)
	}

	if err := os.Remove(gone); err != nil {
		t.Fatal(err)
	}
	r, _ := s.Scan(context.Background(), now)
	if r.Today.InputTokens != 1 {
		t.Fatalf("deleted file still counted: Today = %+v", r.Today)
	}
}

// Half-hour zones (India, +05:30) put local hour edges on :30 UTC — the
// 15-minute slots must still land each message in the right local hour/day.
func TestScanCache_HalfHourZoneBucketsByLocalHour(t *testing.T) {
	ist, err := time.LoadLocation("Asia/Kolkata")
	if err != nil {
		t.Skip("tzdata unavailable")
	}
	now := time.Date(2026, 5, 22, 14, 0, 0, 0, ist)
	root := t.TempDir()
	writeJSONL(t, root, "s.jsonl", []string{
		assistantLine(time.Date(2026, 5, 22, 0, 10, 0, 0, ist), 1, 0, 0, 0),   // today 00:10
		assistantLine(time.Date(2026, 5, 21, 23, 50, 0, 0, ist), 10, 0, 0, 0), // yesterday 23:50
		assistantLine(time.Date(2026, 5, 22, 13, 40, 0, 0, ist), 100, 0, 0, 0),
	})

	r, err := cachedScanner(t, root).Scan(context.Background(), now)
	if err != nil {
		t.Fatal(err)
	}
	if r.Today.InputTokens != 101 {
		t.Fatalf("Today = %+v, want 101 (yesterday 23:50 excluded)", r.Today)
	}
	last := r.Hourly[len(r.Hourly)-2] // 13:00 slot
	if !last.Start.Equal(time.Date(2026, 5, 22, 13, 0, 0, 0, ist)) || last.Bucket.InputTokens != 100 {
		t.Fatalf("13:00 hourly slot = %+v, want 100 input", last)
	}
}
