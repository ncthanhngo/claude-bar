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
