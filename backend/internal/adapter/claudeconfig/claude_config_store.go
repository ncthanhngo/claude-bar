// Package claudeconfig reads and writes ~/.claude.json, preserving the
// many unrelated fields Claude Code stores there.
package claudeconfig

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// readRetryAttempts and readRetryDelay handle the race where Claude Code
// rewrites ~/.claude.json non-atomically while we read it. The file
// contents land in 2-3 fsync()s, so a Read landing in the middle yields
// truncated/invalid JSON. The write completes within a few hundred ms,
// so a tiny bounded retry resolves the race without user-visible failure.
const (
	readRetryAttempts = 3
	readRetryDelay    = 100 * time.Millisecond
)

// ClaudeConfigStore is the on-disk adapter for ~/.claude.json.
type ClaudeConfigStore struct {
	path string
}

// New returns a store bound to ~/.claude.json.
func New() *ClaudeConfigStore {
	return &ClaudeConfigStore{path: adapter.ClaudeConfigFile()}
}

// NewAt is for tests.
func NewAt(path string) *ClaudeConfigStore { return &ClaudeConfigStore{path: path} }

// Exists reports whether the file is on disk.
func (s *ClaudeConfigStore) Exists() bool {
	_, err := os.Stat(s.path)
	return err == nil
}

// Read returns the parsed config plus the raw map so unknown fields survive a Write.
func (s *ClaudeConfigStore) Read(ctx context.Context) (*domain.ClaudeConfig, error) {
	var lastErr error
	for attempt := 0; attempt < readRetryAttempts; attempt++ {
		cfg, err := s.readOnce()
		if err == nil {
			return cfg, nil
		}
		// Only retry on JSON parse errors — those are the race signature.
		// Disk read errors (perm denied, IO failure) are not transient and
		// must surface immediately.
		var syntaxErr *json.SyntaxError
		var typeErr *json.UnmarshalTypeError
		if !errors.As(err, &syntaxErr) && !errors.As(err, &typeErr) {
			return nil, err
		}
		lastErr = err
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(readRetryDelay):
		}
	}
	return nil, lastErr
}

func (s *ClaudeConfigStore) readOnce() (*domain.ClaudeConfig, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return &domain.ClaudeConfig{Raw: map[string]any{}}, nil
		}
		return nil, err
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}
	cfg := &domain.ClaudeConfig{Raw: raw}
	if oa, ok := raw["oauthAccount"]; ok {
		b, _ := json.Marshal(oa)
		var acct domain.OAuthAccount
		if err := json.Unmarshal(b, &acct); err == nil {
			cfg.OAuthAccount = &acct
		}
	}
	return cfg, nil
}

// Write atomically replaces ~/.claude.json with OAuthAccount swapped in,
// keeping all other fields intact.
func (s *ClaudeConfigStore) Write(ctx context.Context, cfg *domain.ClaudeConfig) error {
	if cfg.Raw == nil {
		cfg.Raw = map[string]any{}
	}
	if cfg.OAuthAccount != nil {
		cfg.Raw["oauthAccount"] = cfg.OAuthAccount
	}
	data, err := json.MarshalIndent(cfg.Raw, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(s.path)
	tmp, err := os.CreateTemp(dir, ".claude-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, s.path)
}
