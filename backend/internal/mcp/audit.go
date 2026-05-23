package mcp

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// AuditKind tags the source of an audit event.
type AuditKind string

const (
	AuditKindMCPWrite        AuditKind = "mcp.write"
	AuditKindMCPReadSensitive AuditKind = "mcp.read-sensitive"
	AuditKindSSHConnect      AuditKind = "ssh.connect"
	AuditKindSSHExec         AuditKind = "ssh.exec"
	AuditKindClaudeSpawn     AuditKind = "claude.spawn"
	AuditKindGateApprove     AuditKind = "gate.approve"
	AuditKindGateCancel      AuditKind = "gate.cancel"
	AuditKindGateTimeout     AuditKind = "gate.timeout"
)

// AuditEvent is one append-only line in audit.log. Args are hashed, never
// stored raw — the hash lets later forensics tie a log line to a known
// invocation without leaking secret payloads.
type AuditEvent struct {
	Ts       time.Time `json:"ts"`
	Kind     AuditKind `json:"kind"`
	Tool     string    `json:"tool,omitempty"`
	Account  string    `json:"account,omitempty"`
	Outcome  string    `json:"outcome"`  // "ok" | "user_cancelled" | "timeout" | "error:<code>"
	Latency  int64     `json:"latencyMs,omitempty"`
	ArgsHash string    `json:"argsHash,omitempty"`
}

// AuditWriter is the package-level append-only sink for audit events. Phase 10
// will harden this with rotation, retention, and a flock; the skeleton here is
// enough for Phase 2 to start emitting events.
//
// Zero value is unusable — callers must obtain one via DefaultAuditWriter().
type AuditWriter struct {
	path string
	mu   sync.Mutex
}

var (
	defaultAuditOnce sync.Once
	defaultAudit     *AuditWriter
	defaultAuditErr  error
)

// DefaultAuditWriter returns the process-wide writer pointing at
// ~/Library/Application Support/claude-swap-widget/audit.log on macOS.
// The directory is created on first call.
func DefaultAuditWriter() (*AuditWriter, error) {
	defaultAuditOnce.Do(func() {
		dir, err := defaultAuditDir()
		if err != nil {
			defaultAuditErr = err
			return
		}
		if err := os.MkdirAll(dir, 0o700); err != nil {
			defaultAuditErr = fmt.Errorf("audit mkdir: %w", err)
			return
		}
		defaultAudit = &AuditWriter{path: filepath.Join(dir, "audit.log")}
	})
	return defaultAudit, defaultAuditErr
}

// NewAuditWriter constructs an AuditWriter at the given path. Test-only.
func NewAuditWriter(path string) *AuditWriter {
	return &AuditWriter{path: path}
}

// Path returns the file the writer appends to.
func (w *AuditWriter) Path() string { return w.path }

// Write appends one JSON-lines record. Synchronous + fsync; correctness wins
// over throughput for an audit log. Caller errors are returned but never
// propagated up to the LLM — caller logs and continues.
func (w *AuditWriter) Write(_ context.Context, ev AuditEvent) error {
	if w == nil {
		return nil
	}
	if ev.Ts.IsZero() {
		ev.Ts = time.Now().UTC()
	}
	line, err := json.Marshal(ev)
	if err != nil {
		return fmt.Errorf("audit marshal: %w", err)
	}
	line = append(line, '\n')

	w.mu.Lock()
	defer w.mu.Unlock()

	f, err := os.OpenFile(w.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("audit open: %w", err)
	}
	if _, err := f.Write(line); err != nil {
		_ = f.Close()
		return fmt.Errorf("audit write: %w", err)
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return fmt.Errorf("audit fsync: %w", err)
	}
	return f.Close()
}

// HashArgs returns a sha256 hex digest of the canonical JSON of args. Used so
// audit lines can identify a call without storing secret payloads. Returns ""
// when args is nil/empty.
func HashArgs(args map[string]any) string {
	if len(args) == 0 {
		return ""
	}
	b, err := json.Marshal(args)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func defaultAuditDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("home dir: %w", err)
	}
	return filepath.Join(home, "Library", "Application Support", "claude-swap-widget"), nil
}
