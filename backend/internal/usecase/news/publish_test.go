package news

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	sshadp "github.com/soi/claude-swap-widget/backend/internal/adapter/ssh"
)

// remoteWriteCall records one ExecStdin invocation for assertions.
type remoteWriteCall struct {
	cmd   string
	stdin []byte
}

func fakeExecStdin(calls *[]remoteWriteCall, exitCode int, stderr string) remoteWriter {
	return func(_ context.Context, _ sshadp.TrackedHost, cmd string, stdin []byte, _ time.Duration) (*sshadp.ExecResult, error) {
		*calls = append(*calls, remoteWriteCall{cmd: cmd, stdin: append([]byte(nil), stdin...)})
		return &sshadp.ExecResult{ExitCode: exitCode, Stderr: stderr}, nil
	}
}

func writeLocalNewsFixture(t *testing.T, dir string, body string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir fixture dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "news.json"), []byte(body), 0o600); err != nil {
		t.Fatalf("write news.json fixture: %v", err)
	}
}

func TestPublisher_Publish_WritesNewsThenManifest(t *testing.T) {
	dir := t.TempDir()
	newsBody := `{"schemaVersion":1,"generatedAt":"2026-08-15T08:00:00Z","items":[],"repos":[],"sourcesHealth":{}}`
	writeLocalNewsFixture(t, dir, newsBody)

	var calls []remoteWriteCall
	p := &Publisher{
		Hosts:     fakeHostGetter{host: &sshadp.TrackedHost{Name: "relay"}},
		ExecStdin: fakeExecStdin(&calls, 0, ""),
		Now:       func() time.Time { return time.Date(2026, 8, 15, 9, 0, 0, 0, time.UTC) },
		Timeout:   5 * time.Second,
		Dir:       dir,
	}

	if err := p.Publish(context.Background(), "relay", "/relay"); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if len(calls) != 2 {
		t.Fatalf("expected 2 remote writes (news then manifest), got %d", len(calls))
	}
	if !strings.Contains(calls[0].cmd, "news.json") {
		t.Errorf("first write should target news.json, cmd = %q", calls[0].cmd)
	}
	if string(calls[0].stdin) != newsBody {
		t.Errorf("first write stdin = %q, want the exact local news.json bytes", calls[0].stdin)
	}
	if !strings.Contains(calls[1].cmd, "manifest.json") {
		t.Errorf("second write should target manifest.json, cmd = %q", calls[1].cmd)
	}
	var manifest NewsManifest
	if err := json.Unmarshal(calls[1].stdin, &manifest); err != nil {
		t.Fatalf("manifest stdin not valid JSON: %v", err)
	}
	if manifest.GeneratedAt != "2026-08-15T08:00:00Z" {
		t.Errorf("manifest.GeneratedAt = %q, want the snapshot's own GeneratedAt", manifest.GeneratedAt)
	}
}

func TestPublisher_Publish_NoLocalSnapshotErrorsCleanly(t *testing.T) {
	p := &Publisher{
		Hosts:     fakeHostGetter{host: &sshadp.TrackedHost{Name: "relay"}},
		ExecStdin: fakeExecStdin(new([]remoteWriteCall), 0, ""),
		Dir:       t.TempDir(), // empty — no news.json written
	}
	err := p.Publish(context.Background(), "relay", "/relay")
	if err == nil {
		t.Fatal("expected error when no local news.json exists")
	}
}

func TestPublisher_Publish_RemoteWriteFailureSurfacesStderr(t *testing.T) {
	dir := t.TempDir()
	writeLocalNewsFixture(t, dir, `{"generatedAt":"2026-08-15T08:00:00Z","items":[]}`)

	var calls []remoteWriteCall
	p := &Publisher{
		Hosts:     fakeHostGetter{host: &sshadp.TrackedHost{Name: "relay"}},
		ExecStdin: fakeExecStdin(&calls, 1, "permission denied"),
		Dir:       dir,
	}
	err := p.Publish(context.Background(), "relay", "/relay")
	if err == nil {
		t.Fatal("expected error on non-zero remote exit code")
	}
	if !strings.Contains(err.Error(), "permission denied") {
		t.Errorf("error should surface remote stderr, got: %v", err)
	}
}

func TestPublisher_Publish_RequiresHostAndDir(t *testing.T) {
	p := &Publisher{Hosts: fakeHostGetter{}, ExecStdin: fakeExecStdin(new([]remoteWriteCall), 0, ""), Dir: t.TempDir()}
	if err := p.Publish(context.Background(), "", "/relay"); err == nil {
		t.Error("expected error for empty host")
	}
	if err := p.Publish(context.Background(), "relay", ""); err == nil {
		t.Error("expected error for empty remote dir")
	}
}
