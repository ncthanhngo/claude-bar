// Package cache also tracks rate-limit cooldown so the widget does not hammer
// Anthropic's Cloudflare WAF after a 429. Each 429 escalates the cooldown
// (1m → 5m → 15m → 30m → 60m, capped). A successful call resets it.
package cache

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
)

// BackoffState persists the next time we are allowed to call the usage API.
type BackoffState struct {
	NextAttemptAt time.Time `json:"nextAttemptAt"`
	ConsecutiveHits int     `json:"consecutiveHits"`
}

// Backoff is the file-backed cooldown tracker.
type Backoff struct {
	path string
	mu   sync.Mutex
}

// NewBackoff returns a Backoff at the default widget data path.
func NewBackoff() *Backoff {
	return &Backoff{path: filepath.Join(adapter.WidgetDataDir(), "backoff.json")}
}

// ShouldSkip reports whether we are still in cooldown.
func (b *Backoff) ShouldSkip() (bool, time.Duration) {
	st := b.load()
	if st.NextAttemptAt.IsZero() {
		return false, 0
	}
	remaining := time.Until(st.NextAttemptAt)
	if remaining <= 0 {
		return false, 0
	}
	return true, remaining
}

// RecordRateLimit escalates the cooldown after a 429.
func (b *Backoff) RecordRateLimit() {
	b.mu.Lock()
	defer b.mu.Unlock()
	st := b.loadLocked()
	st.ConsecutiveHits++
	st.NextAttemptAt = time.Now().Add(escalate(st.ConsecutiveHits))
	_ = b.saveLocked(st)
}

// RecordSuccess clears the cooldown after a 2xx response.
func (b *Backoff) RecordSuccess() {
	b.mu.Lock()
	defer b.mu.Unlock()
	_ = b.saveLocked(BackoffState{})
}

func escalate(hits int) time.Duration {
	switch {
	case hits <= 1:  return 1 * time.Minute
	case hits == 2:  return 5 * time.Minute
	case hits == 3:  return 15 * time.Minute
	case hits == 4:  return 30 * time.Minute
	default:         return 60 * time.Minute
	}
}

func (b *Backoff) load() BackoffState {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.loadLocked()
}

func (b *Backoff) loadLocked() BackoffState {
	data, err := os.ReadFile(b.path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return BackoffState{}
		}
		return BackoffState{}
	}
	var st BackoffState
	if err := json.Unmarshal(data, &st); err != nil {
		return BackoffState{}
	}
	return st
}

func (b *Backoff) saveLocked(st BackoffState) error {
	if err := adapter.EnsureDataDir(); err != nil {
		return err
	}
	data, _ := json.MarshalIndent(st, "", "  ")
	dir := filepath.Dir(b.path)
	tmp, err := os.CreateTemp(dir, "backoff-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	tmp.Close()
	return adapter.ReplaceFile(tmpName, b.path)
}
