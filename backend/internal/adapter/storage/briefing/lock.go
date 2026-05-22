package briefingstore

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/usecase/briefing"
)

// ErrAlreadyRunning is returned when another process holds the run lock.
var ErrAlreadyRunning = errors.New("briefing already running")

// staleLockAge — lock files older than this are treated as crash leftovers.
const staleLockAge = 10 * time.Minute

// RunLock is a per-host advisory flock that serialises briefing runs.
type RunLock struct {
	path string
	f    *os.File
}

// NewRunLock returns a lock at the canonical briefings/.run.lock path.
func NewRunLock() (*RunLock, error) {
	path, err := briefing.RunLockFile()
	if err != nil {
		return nil, err
	}
	return &RunLock{path: path}, nil
}

// Acquire takes the lock or returns ErrAlreadyRunning.
// If the existing lock is stale (>10m or PID dead) it is force-released.
func (l *RunLock) Acquire(ctx context.Context) error {
	l.evictStale()

	f, err := os.OpenFile(l.path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			l.f = f
			// Record PID + start time for diagnostics + staleness check.
			_ = f.Truncate(0)
			_, _ = f.Seek(0, 0)
			fmt.Fprintf(f, "%d\n%d\n", os.Getpid(), time.Now().Unix())
			return nil
		}
		if err != syscall.EWOULDBLOCK {
			f.Close()
			return err
		}
		select {
		case <-ctx.Done():
			f.Close()
			return ErrAlreadyRunning
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// Release frees the lock. Safe to call once.
func (l *RunLock) Release() {
	if l.f == nil {
		return
	}
	_ = syscall.Flock(int(l.f.Fd()), syscall.LOCK_UN)
	_ = l.f.Close()
	_ = os.Remove(l.path)
	l.f = nil
}

// evictStale removes a lock file that is older than staleLockAge or whose
// recorded PID is no longer running.
func (l *RunLock) evictStale() {
	info, err := os.Stat(l.path)
	if err != nil {
		return
	}
	if time.Since(info.ModTime()) > staleLockAge {
		_ = os.Remove(l.path)
		return
	}
	data, err := os.ReadFile(l.path)
	if err != nil {
		return
	}
	parts := strings.SplitN(strings.TrimSpace(string(data)), "\n", 2)
	if len(parts) == 0 {
		return
	}
	pid, err := strconv.Atoi(strings.TrimSpace(parts[0]))
	if err != nil || pid <= 0 {
		return
	}
	// Signal 0 probes liveness without delivering a signal.
	proc, err := os.FindProcess(pid)
	if err != nil {
		return
	}
	if err := proc.Signal(syscall.Signal(0)); err != nil {
		_ = os.Remove(l.path)
	}
}
