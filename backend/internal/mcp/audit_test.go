package mcp

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestAuditWriterAppendsJSONLines(t *testing.T) {
	dir := t.TempDir()
	w := NewAuditWriter(filepath.Join(dir, "audit.log"))

	events := []AuditEvent{
		{Kind: AuditKindMCPWrite, Tool: "cb_github_post_review", Outcome: "ok", Account: "1"},
		{Kind: AuditKindGateCancel, Tool: "cb_github_merge_pr", Outcome: "user_cancelled"},
	}
	for _, ev := range events {
		if err := w.Write(context.Background(), ev); err != nil {
			t.Fatalf("write: %v", err)
		}
	}

	f, err := os.Open(w.Path())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer f.Close()

	var lines []AuditEvent
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var ev AuditEvent
		if err := json.Unmarshal(sc.Bytes(), &ev); err != nil {
			t.Fatalf("decode %q: %v", sc.Text(), err)
		}
		lines = append(lines, ev)
	}
	if len(lines) != 2 {
		t.Fatalf("want 2 lines, got %d", len(lines))
	}
	if lines[0].Kind != AuditKindMCPWrite || lines[0].Tool != "cb_github_post_review" {
		t.Fatalf("line 0 mismatch: %+v", lines[0])
	}
	if lines[1].Outcome != "user_cancelled" {
		t.Fatalf("line 1 outcome: %q", lines[1].Outcome)
	}
	if lines[0].Ts.IsZero() {
		t.Fatalf("auto Ts should be set")
	}
}

func TestAuditWriterPermissionsAndConcurrency(t *testing.T) {
	dir := t.TempDir()
	w := NewAuditWriter(filepath.Join(dir, "audit.log"))

	const n = 50
	var wg sync.WaitGroup
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func() {
			defer wg.Done()
			_ = w.Write(context.Background(), AuditEvent{Kind: AuditKindMCPWrite, Outcome: "ok", Ts: time.Now()})
		}()
	}
	wg.Wait()

	st, err := os.Stat(w.Path())
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("perm = %o, want 0600", st.Mode().Perm())
	}

	data, err := os.ReadFile(w.Path())
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	got := strings.Count(string(data), "\n")
	if got != n {
		t.Fatalf("lines = %d, want %d (interleaved writes lost data)", got, n)
	}
}

func TestAuditWriterRotatesOnDayChange(t *testing.T) {
	dir := t.TempDir()
	w := NewAuditWriter(filepath.Join(dir, "audit.log"))

	// Yesterday's event.
	yesterday := time.Now().Add(-26 * time.Hour)
	if err := w.Write(context.Background(), AuditEvent{Kind: AuditKindMCPWrite, Outcome: "ok", Ts: yesterday}); err != nil {
		t.Fatalf("write: %v", err)
	}
	// Backdate the file's mtime so rotateIfStale picks it up.
	if err := os.Chtimes(w.Path(), yesterday, yesterday); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	// Today's event — should trigger a rotate.
	if err := w.Write(context.Background(), AuditEvent{Kind: AuditKindGateApprove, Outcome: "ok"}); err != nil {
		t.Fatalf("write today: %v", err)
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	var sawActive, sawRotated bool
	for _, e := range entries {
		switch {
		case e.Name() == "audit.log":
			sawActive = true
		case strings.HasPrefix(e.Name(), "audit-") && strings.HasSuffix(e.Name(), ".log"):
			sawRotated = true
		}
	}
	if !sawActive || !sawRotated {
		t.Fatalf("expected active+rotated; entries=%v", listNames(entries))
	}
}

func TestAuditWriterSweepRetention(t *testing.T) {
	dir := t.TempDir()
	w := NewAuditWriter(filepath.Join(dir, "audit.log"))

	now := time.Now()
	old := now.AddDate(0, 0, -40).Format("2006-01-02")
	recent := now.AddDate(0, 0, -10).Format("2006-01-02")

	mustWrite(t, filepath.Join(dir, "audit-"+old+".log"), "old")
	mustWrite(t, filepath.Join(dir, "audit-"+recent+".log"), "recent")
	mustWrite(t, filepath.Join(dir, "audit.log"), "active")
	mustWrite(t, filepath.Join(dir, "unrelated.txt"), "nope")

	deleted, err := w.SweepRetention(now, 30)
	if err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if deleted != 1 {
		t.Fatalf("deleted = %d, want 1", deleted)
	}
	if _, err := os.Stat(filepath.Join(dir, "audit-"+old+".log")); !os.IsNotExist(err) {
		t.Errorf("old file should have been deleted")
	}
	for _, keep := range []string{"audit-" + recent + ".log", "audit.log", "unrelated.txt"} {
		if _, err := os.Stat(filepath.Join(dir, keep)); err != nil {
			t.Errorf("%s should still exist: %v", keep, err)
		}
	}
}

func TestAuditWriterSweepNoOpWhenForever(t *testing.T) {
	dir := t.TempDir()
	w := NewAuditWriter(filepath.Join(dir, "audit.log"))
	mustWrite(t, filepath.Join(dir, "audit-2020-01-01.log"), "ancient")
	n, err := w.SweepRetention(time.Now(), 0)
	if err != nil || n != 0 {
		t.Fatalf("sweep with keep=0 should be no-op: n=%d err=%v", n, err)
	}
}

func mustWrite(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func listNames(es []os.DirEntry) []string {
	out := make([]string, 0, len(es))
	for _, e := range es {
		out = append(out, e.Name())
	}
	return out
}

func TestHashArgsStableAndOmitEmpty(t *testing.T) {
	if HashArgs(nil) != "" {
		t.Fatalf("nil args should hash to empty string")
	}
	if HashArgs(map[string]any{}) != "" {
		t.Fatalf("empty args should hash to empty string")
	}
	a := HashArgs(map[string]any{"pr": 12, "body": "lgtm"})
	b := HashArgs(map[string]any{"pr": 12, "body": "lgtm"})
	if a == "" || a != b {
		t.Fatalf("hash should be stable: a=%q b=%q", a, b)
	}
	c := HashArgs(map[string]any{"pr": 13, "body": "lgtm"})
	if a == c {
		t.Fatalf("different args should hash differently")
	}
}
