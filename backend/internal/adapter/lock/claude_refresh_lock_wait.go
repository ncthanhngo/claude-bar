package lock

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
)

// claudeRefreshLockName is the proper-lockfile directory Claude Code holds
// while it refreshes its own OAuth token. It touches the directory every 5s
// and treats it as stale after 60s.
const claudeRefreshLockName = ".oauth_refresh.lock"

const claudeRefreshLockStaleAfter = 60 * time.Second

// ClaudeRefreshLockWait waits (without acquiring) for Claude Code to finish
// an in-flight token refresh, so a swap cannot write the live slot just
// before Claude Code saves the outgoing account's refreshed token over it.
type ClaudeRefreshLockWait struct {
	path    string
	poll    time.Duration
	timeout time.Duration
}

// NewClaudeRefreshLockWait watches the lock under ~/.claude.
func NewClaudeRefreshLockWait() *ClaudeRefreshLockWait {
	return NewClaudeRefreshLockWaitAt(adapter.ClaudeConfigDir())
}

// NewClaudeRefreshLockWaitAt is for tests.
func NewClaudeRefreshLockWaitAt(claudeDir string) *ClaudeRefreshLockWait {
	return &ClaudeRefreshLockWait{
		path:    filepath.Join(claudeDir, claudeRefreshLockName),
		poll:    250 * time.Millisecond,
		timeout: 10 * time.Second,
	}
}

// WaitReleased returns once the lock is absent or stale, the timeout passes,
// or ctx is done. Giving up is deliberate: the swap must not hang on a lock
// whose format a future Claude Code version may change.
func (w *ClaudeRefreshLockWait) WaitReleased(ctx context.Context) {
	deadline := time.Now().Add(w.timeout)
	for w.held() {
		if !time.Now().Before(deadline) {
			log.Printf("[lock] %s still held after %v; proceeding", w.path, w.timeout)
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(w.poll):
		}
	}
}

func (w *ClaudeRefreshLockWait) held() bool {
	info, err := os.Stat(w.path)
	if err != nil {
		return false
	}
	return time.Since(info.ModTime()) < claudeRefreshLockStaleAfter
}
