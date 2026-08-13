package backup

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// ProfileStore is the on-disk JSON registry of backup profiles. Mirrors the
// HostStore pattern: single JSON file, atomic temp+rename write, 0600 perms.
type ProfileStore struct {
	path string
	mu   sync.Mutex
}

// NewProfileStore returns a store backed by `path` (canonical path is
// adapter.WidgetDataDir()/backups/profiles.json, or a per-test temp file).
func NewProfileStore(path string) *ProfileStore {
	return &ProfileStore{path: path}
}

// List returns all profiles sorted by name. Never returns nil — callers and the
// Swift decoder both expect [].
func (s *ProfileStore) List(_ context.Context) ([]BackupProfile, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	profiles, err := s.load()
	if err != nil {
		return nil, err
	}
	sort.Slice(profiles, func(i, j int) bool { return profiles[i].Name < profiles[j].Name })
	return profiles, nil
}

// Get returns the profile with id, or an error if absent.
func (s *ProfileStore) Get(_ context.Context, id string) (*BackupProfile, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	profiles, err := s.load()
	if err != nil {
		return nil, err
	}
	for _, p := range profiles {
		if p.ID == id {
			cp := p
			return &cp, nil
		}
	}
	return nil, fmt.Errorf("backup profile %q not found", id)
}

// Save upserts a profile. An empty ID gets a fresh uuid + CreatedAt; an existing
// ID preserves CreatedAt and bumps UpdatedAt. Defaults are filled and the result
// validated before persisting. Returns the stored profile.
func (s *ProfileStore) Save(_ context.Context, p BackupProfile) (*BackupProfile, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	profiles, err := s.load()
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	if p.ID == "" {
		p.ID = newID()
		p.CreatedAt = now
	}
	p.UpdatedAt = now
	p.normalize()
	if err := p.Validate(); err != nil {
		return nil, err
	}

	replaced := false
	for i, e := range profiles {
		if e.ID == p.ID {
			if p.CreatedAt.IsZero() {
				p.CreatedAt = e.CreatedAt
			}
			if p.LastInstalledAt == nil {
				p.LastInstalledAt = e.LastInstalledAt
			}
			profiles[i] = p
			replaced = true
			break
		}
	}
	if !replaced {
		if p.CreatedAt.IsZero() {
			p.CreatedAt = now
		}
		profiles = append(profiles, p)
	}
	if err := s.save(profiles); err != nil {
		return nil, err
	}
	cp := p
	return &cp, nil
}

// MarkInstalled stamps LastInstalledAt for id without rewriting other fields.
func (s *ProfileStore) MarkInstalled(ctx context.Context, id string, when time.Time) error {
	p, err := s.Get(ctx, id)
	if err != nil {
		return err
	}
	p.LastInstalledAt = &when
	_, err = s.Save(ctx, *p)
	return err
}

// Delete removes the profile with id (no error if already absent).
func (s *ProfileStore) Delete(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	profiles, err := s.load()
	if err != nil {
		return err
	}
	out := make([]BackupProfile, 0, len(profiles))
	for _, e := range profiles {
		if e.ID != id {
			out = append(out, e)
		}
	}
	return s.save(out)
}

// --- private file IO ---

func (s *ProfileStore) load() ([]BackupProfile, error) {
	b, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return []BackupProfile{}, nil
		}
		return nil, fmt.Errorf("profile store read: %w", err)
	}
	if len(b) == 0 {
		return []BackupProfile{}, nil
	}
	var profiles []BackupProfile
	if err := json.Unmarshal(b, &profiles); err != nil {
		return nil, fmt.Errorf("profile store decode: %w", err)
	}
	if profiles == nil {
		profiles = []BackupProfile{}
	}
	return profiles, nil
}

func (s *ProfileStore) save(profiles []BackupProfile) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	b, err := json.MarshalIndent(profiles, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

// newID returns a 16-byte random hex id. Dependency-free (no external uuid pkg)
// and collision-safe for this scale.
func newID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		// rand.Read only fails on a broken platform RNG; fall back to time.
		return hex.EncodeToString([]byte(time.Now().UTC().Format("20060102150405.000000000")))
	}
	return hex.EncodeToString(b[:])
}
