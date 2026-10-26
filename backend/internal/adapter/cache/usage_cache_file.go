// Package cache persists per-account usage responses so multiple `csw list`
// invocations and the widget's polling loop don't all hit the Anthropic API.
//
// Behaviour: 90s TTL for "fresh"; entries older than that are still returned
// as fallback when a live fetch fails (e.g. 429 rate limit) — the UI then
// shows the last-known value instead of an error.
package cache

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// DefaultTTL is the freshness window for live cache hits.
const DefaultTTL = 90 * time.Second

// Entry stores one cached usage value with its write time.
type Entry struct {
	Usage     *domain.Usage `json:"usage"`
	WrittenAt time.Time     `json:"writtenAt"`
}

// UsageCache is a file-backed map[accountNum]Entry.
type UsageCache struct {
	path string
	ttl  time.Duration
	mu   sync.Mutex
}

// New returns a cache at the default widget data path.
func New() *UsageCache {
	return &UsageCache{path: adapter.UsageCacheFile(), ttl: DefaultTTL}
}

// NewAt is for tests.
func NewAt(path string, ttl time.Duration) *UsageCache {
	return &UsageCache{path: path, ttl: ttl}
}

// Get returns (entry, isFresh). entry may be nil if no record at all.
func (c *UsageCache) Get(accountNum int) (*Entry, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	all := c.loadLocked()
	e, ok := all[accountNum]
	if !ok {
		return nil, false
	}
	fresh := time.Since(e.WrittenAt) < c.ttl
	return e, fresh
}

// Put writes a fresh entry.
func (c *UsageCache) Put(accountNum int, u *domain.Usage) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	all := c.loadLocked()
	all[accountNum] = &Entry{Usage: u, WrittenAt: time.Now().UTC()}
	return c.saveLocked(all)
}

// Drop removes one entry (called after account removal).
func (c *UsageCache) Drop(accountNum int) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	all := c.loadLocked()
	delete(all, accountNum)
	return c.saveLocked(all)
}

func (c *UsageCache) loadLocked() map[int]*Entry {
	data, err := os.ReadFile(c.path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return map[int]*Entry{}
		}
		return map[int]*Entry{}
	}
	var raw map[string]*Entry
	if err := json.Unmarshal(data, &raw); err != nil {
		return map[int]*Entry{}
	}
	out := make(map[int]*Entry, len(raw))
	for k, v := range raw {
		if n, err := strconv.Atoi(k); err == nil {
			out[n] = v
		}
	}
	return out
}

func (c *UsageCache) saveLocked(all map[int]*Entry) error {
	if err := adapter.EnsureDataDir(); err != nil {
		return err
	}
	raw := make(map[string]*Entry, len(all))
	for k, v := range all {
		raw[strconv.Itoa(k)] = v
	}
	data, err := json.MarshalIndent(raw, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(c.path)
	tmp, err := os.CreateTemp(dir, "usage-*.tmp")
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
	return adapter.ReplaceFile(tmpName, c.path)
}
