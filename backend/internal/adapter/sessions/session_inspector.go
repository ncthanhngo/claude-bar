// Package sessions reads ~/.claude/sessions/{pid}.json to detect live Claude
// Code processes. Uses the same source of truth as Claude Code itself.
package sessions

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"syscall"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// SessionInspector lists live sessions and produces a safe-to-swap report.
type SessionInspector struct {
	dir string
}

// New binds to ~/.claude/sessions.
func New() *SessionInspector {
	return &SessionInspector{dir: adapter.ClaudeSessionsDir()}
}

// NewAt is for tests.
func NewAt(dir string) *SessionInspector { return &SessionInspector{dir: dir} }

// List returns sessions whose PID is still alive.
func (i *SessionInspector) List(ctx context.Context) ([]domain.ClaudeSession, error) {
	entries, err := os.ReadDir(i.dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	out := make([]domain.ClaudeSession, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".json" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(i.dir, e.Name()))
		if err != nil {
			continue
		}
		var s domain.ClaudeSession
		if err := json.Unmarshal(data, &s); err != nil {
			continue
		}
		if !isPIDAlive(s.PID) {
			continue
		}
		out = append(out, s)
	}
	return out, nil
}

// Report summarises sessions into a swap-safety decision.
func (i *SessionInspector) Report(ctx context.Context) (*domain.SessionReport, error) {
	sessions, err := i.List(ctx)
	if err != nil {
		return nil, err
	}
	r := &domain.SessionReport{Total: len(sessions)}
	for _, s := range sessions {
		if s.IsBusy() {
			r.BusyOrWaiting++
		}
		if s.IsInteractive() {
			r.InteractiveOnly++
		}
		if s.BlocksSwap() {
			r.BlockingCount++
		}
	}
	// Any live interactive or bg claude session blocks swap — even if status is
	// idle. PID-status files can lag real process state, and swapping while
	// claude is open forces user to restart mid-session.
	r.SafeToSwap = r.BlockingCount == 0
	return r, nil
}

// isPIDAlive returns true iff a process with this pid exists. Uses kill(pid, 0)
// which returns EPERM if alive-but-not-ours (still alive), ESRCH if dead.
func isPIDAlive(pid int) bool {
	if pid <= 1 {
		return false
	}
	err := syscall.Kill(pid, 0)
	if err == nil {
		return true
	}
	return err == syscall.EPERM
}
