package ssh

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// TrackedHost is a host the user has opted to manage via the app. The Name
// matches the SSH config Host stanza; the optional fields override config
// values when set.
type TrackedHost struct {
	Name          string    `json:"name"`
	HostName      string    `json:"hostName,omitempty"`
	Port          int       `json:"port,omitempty"`
	User          string    `json:"user,omitempty"`
	IdentityFile  string    `json:"identityFile,omitempty"`
	JumpHost      string    `json:"jumpHost,omitempty"`
	Note          string    `json:"note,omitempty"`
	AddedAt       time.Time `json:"addedAt"`
	LastConnected time.Time `json:"lastConnected,omitempty"`
}

// HostStore is the on-disk JSON registry of tracked SSH hosts.
type HostStore struct {
	path string
	mu   sync.Mutex
}

// NewHostStore returns a store backed by `path`. Pass the canonical path
// (`adapter.WidgetDataDir()/ssh/hosts.json`) or a per-test temp file.
func NewHostStore(path string) *HostStore {
	return &HostStore{path: path}
}

func (s *HostStore) List(_ context.Context) ([]TrackedHost, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	hosts, err := s.load()
	if err != nil {
		return nil, err
	}
	sort.Slice(hosts, func(i, j int) bool { return hosts[i].Name < hosts[j].Name })
	return hosts, nil
}

func (s *HostStore) Put(_ context.Context, h TrackedHost) error {
	if h.Name == "" {
		return errors.New("host name required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	hosts, err := s.load()
	if err != nil {
		return err
	}
	if h.AddedAt.IsZero() {
		h.AddedAt = time.Now().UTC()
	}
	replaced := false
	for i, e := range hosts {
		if e.Name == h.Name {
			hosts[i] = h
			replaced = true
			break
		}
	}
	if !replaced {
		hosts = append(hosts, h)
	}
	return s.save(hosts)
}

func (s *HostStore) Delete(_ context.Context, name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	hosts, err := s.load()
	if err != nil {
		return err
	}
	out := make([]TrackedHost, 0, len(hosts))
	for _, e := range hosts {
		if e.Name != name {
			out = append(out, e)
		}
	}
	return s.save(out)
}

func (s *HostStore) Get(ctx context.Context, name string) (*TrackedHost, error) {
	hosts, err := s.List(ctx)
	if err != nil {
		return nil, err
	}
	for _, h := range hosts {
		if h.Name == name {
			cp := h
			return &cp, nil
		}
	}
	return nil, fmt.Errorf("host %q not tracked", name)
}

func (s *HostStore) MarkConnected(ctx context.Context, name string, when time.Time) error {
	h, err := s.Get(ctx, name)
	if err != nil {
		return err
	}
	h.LastConnected = when
	return s.Put(ctx, *h)
}

// MergeFromConfig adds (does not remove) hosts from the parsed ~/.ssh/config.
// Names already in the store keep their state; new names land with the
// config-provided fields. Returns the names that were added.
func (s *HostStore) MergeFromConfig(ctx context.Context, parsed []HostEntry) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	current, err := s.load()
	if err != nil {
		return nil, err
	}
	idx := make(map[string]bool, len(current))
	for _, h := range current {
		idx[h.Name] = true
	}
	added := []string{}
	now := time.Now().UTC()
	for _, p := range parsed {
		if p.IsWildcard() || idx[p.Name] {
			continue
		}
		current = append(current, TrackedHost{
			Name:         p.Name,
			HostName:     p.HostName,
			Port:         p.Port,
			User:         p.User,
			IdentityFile: p.IdentityFile,
			JumpHost:     p.JumpHost,
			AddedAt:      now,
		})
		added = append(added, p.Name)
	}
	if err := s.save(current); err != nil {
		return nil, err
	}
	return added, nil
}

// --- private file IO ---

func (s *HostStore) load() ([]TrackedHost, error) {
	b, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("host store read: %w", err)
	}
	if len(b) == 0 {
		return nil, nil
	}
	var hosts []TrackedHost
	if err := json.Unmarshal(b, &hosts); err != nil {
		return nil, fmt.Errorf("host store decode: %w", err)
	}
	return hosts, nil
}

func (s *HostStore) save(hosts []TrackedHost) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	b, err := json.MarshalIndent(hosts, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}
