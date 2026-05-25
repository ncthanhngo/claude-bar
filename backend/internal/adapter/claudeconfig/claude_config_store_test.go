package claudeconfig

import (
	"context"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// TestReadRetriesOnTruncatedJSONFromConcurrentClaudeCodeWrite simulates the
// race where Claude Code rewrites ~/.claude.json non-atomically while csw
// is in the middle of a swap. A bounded retry must converge once the
// writer finishes, instead of failing the entire swap with a JSON parse
// error that resolves itself within a few hundred ms.
func TestReadRetriesOnTruncatedJSONFromConcurrentClaudeCodeWrite(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "claude.json")

	// Start with valid JSON so the very first read sees a complete file
	// — then the truncate-then-rewrite below stages the race.
	good := []byte(`{"oauthAccount":{"emailAddress":"a@example.com"}}`)
	if err := os.WriteFile(path, good, 0o600); err != nil {
		t.Fatal(err)
	}
	// Truncate to mid-write garbage so the first Read attempt parse-fails.
	if err := os.WriteFile(path, []byte(`{"oauthAccount":{"em`), 0o600); err != nil {
		t.Fatal(err)
	}

	store := NewAt(path)

	// Heal the file shortly after Read starts retrying — readRetryDelay is
	// 100ms so 150ms lands inside the retry window.
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		time.Sleep(150 * time.Millisecond)
		_ = os.WriteFile(path, good, 0o600)
	}()

	cfg, err := store.Read(context.Background())
	wg.Wait()
	if err != nil {
		t.Fatalf("Read should retry past transient JSON parse error: %v", err)
	}
	if cfg == nil || cfg.OAuthAccount == nil || cfg.OAuthAccount.EmailAddress != "a@example.com" {
		t.Fatalf("Read returned %+v, want parsed oauthAccount", cfg)
	}
}

// TestReadDoesNotRetryNonJSONErrors guards against retry-amplifying a real
// disk failure (permission denied, IO error). Only JSON parse errors are
// retryable — anything else returns immediately.
func TestReadDoesNotRetryNonJSONErrors(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "claude.json")
	if err := os.WriteFile(path, []byte(`{"ok":true}`), 0o000); err != nil {
		t.Fatal(err)
	}
	if os.Geteuid() == 0 {
		t.Skip("running as root bypasses 0o000 perm")
	}

	store := NewAt(path)
	start := time.Now()
	_, err := store.Read(context.Background())
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("expected permission denied")
	}
	// If we wrongly retried 3 times at 100ms each, elapsed would be >300ms.
	if elapsed > 50*time.Millisecond {
		t.Fatalf("non-JSON error was retried (elapsed %v); must fail immediately", elapsed)
	}
}

// TestReadReturnsParseErrorWhenRetryWindowExhausted verifies the bounded
// retry actually has a ceiling — a permanently malformed file must surface
// the parse error rather than spin forever.
func TestReadReturnsParseErrorWhenRetryWindowExhausted(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "claude.json")
	if err := os.WriteFile(path, []byte(`{not json`), 0o600); err != nil {
		t.Fatal(err)
	}
	store := NewAt(path)
	_, err := store.Read(context.Background())
	if err == nil {
		t.Fatal("expected JSON parse error after retries exhausted")
	}
}
