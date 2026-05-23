package mcp

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
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
//
// Multi-process safe via syscall.Flock on the open file: concurrent csw
// invocations serialise their appends. Daily-rotation check fires on every
// append — if the active file's mtime is on a prior day, it is renamed to
// `audit-YYYY-MM-DD.log` before the new line is written.
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

	if err := w.rotateIfStale(ev.Ts); err != nil {
		return err
	}

	f, err := os.OpenFile(w.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("audit open: %w", err)
	}
	if err := flockExclusive(f); err != nil {
		_ = f.Close()
		return fmt.Errorf("audit flock: %w", err)
	}
	defer func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		_ = f.Close()
	}()
	if _, err := f.Write(line); err != nil {
		return fmt.Errorf("audit write: %w", err)
	}
	if err := f.Sync(); err != nil {
		return fmt.Errorf("audit fsync: %w", err)
	}
	return nil
}

// rotateIfStale renames audit.log → audit-YYYY-MM-DD.log when the existing
// active file's mtime is on a calendar day prior to `now`. No-ops if the
// file is absent (fresh install) or already today's.
func (w *AuditWriter) rotateIfStale(now time.Time) error {
	st, err := os.Stat(w.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("audit stat: %w", err)
	}
	mtime := st.ModTime()
	if sameLocalDate(mtime, now) {
		return nil
	}
	rotated := filepath.Join(filepath.Dir(w.path), fmt.Sprintf("audit-%s.log", mtime.Format("2006-01-02")))
	// If the rotated path already exists (rare — same-day rotation due to
	// clock skew), keep adding suffixes until unique.
	for i := 1; ; i++ {
		if _, err := os.Stat(rotated); os.IsNotExist(err) {
			break
		}
		rotated = filepath.Join(filepath.Dir(w.path), fmt.Sprintf("audit-%s.%d.log", mtime.Format("2006-01-02"), i))
		if i > 64 {
			return fmt.Errorf("audit rotate: too many same-day rolls")
		}
	}
	if err := os.Rename(w.path, rotated); err != nil {
		return fmt.Errorf("audit rotate: %w", err)
	}
	return nil
}

// SweepRetention deletes audit-YYYY-MM-DD.log files older than `keep` days
// based on the date encoded in the filename. Active `audit.log` is never
// touched. retention<=0 disables the sweep (treat as "forever").
func (w *AuditWriter) SweepRetention(now time.Time, keep int) (int, error) {
	if w == nil || keep <= 0 {
		return 0, nil
	}
	dir := filepath.Dir(w.path)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, fmt.Errorf("audit sweep: %w", err)
	}
	cutoff := now.AddDate(0, 0, -keep)
	deleted := 0
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasPrefix(name, "audit-") || !strings.HasSuffix(name, ".log") {
			continue
		}
		// Parse the YYYY-MM-DD chunk; tolerate same-day suffix `.N` form.
		stem := strings.TrimSuffix(strings.TrimPrefix(name, "audit-"), ".log")
		if dot := strings.Index(stem, "."); dot != -1 {
			stem = stem[:dot]
		}
		d, err := time.Parse("2006-01-02", stem)
		if err != nil {
			continue
		}
		if d.Before(cutoff) {
			if err := os.Remove(filepath.Join(dir, name)); err == nil {
				deleted++
			}
		}
	}
	return deleted, nil
}

func sameLocalDate(a, b time.Time) bool {
	ay, am, ad := a.Date()
	by, bm, bd := b.Date()
	return ay == by && am == bm && ad == bd
}

func flockExclusive(f *os.File) error {
	// Blocking LOCK_EX — the call returns once the lock is granted or fails
	// with a non-EWOULDBLOCK error. Concurrent writers serialise here.
	return syscall.Flock(int(f.Fd()), syscall.LOCK_EX)
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
