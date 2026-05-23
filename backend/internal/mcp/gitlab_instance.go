package mcp

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// GitLabInstance is one user-configured self-host (e.g. "vault.gem.help").
// The PAT lives in Keychain under
// `claude-bar-mcp:shared:gitlab:<instanceId>` (Phase 1 multi-token format).
// This struct holds only the non-secret metadata.
type GitLabInstance struct {
	ID      string    `json:"id"`              // ulid / random hex
	Name    string    `json:"name"`            // user-facing label
	BaseURL string    `json:"baseUrl"`         // "https://vault.gem.help/api/v4"
	AddedAt time.Time `json:"addedAt"`
	Note    string    `json:"note,omitempty"`
}

// GitLabInstanceStore is the on-disk registry of self-host GitLab
// instances. Stored separately from the Claude account registry because
// instances are shared across all Claude accounts on the machine.
type GitLabInstanceStore struct {
	path string
	mu   sync.Mutex
}

// NewGitLabInstanceStore builds a store backed by `path`. Pass the canonical
// `~/Library/Application Support/.../gitlab-instances.json` or a temp file
// in tests.
func NewGitLabInstanceStore(path string) *GitLabInstanceStore {
	return &GitLabInstanceStore{path: path}
}

func (s *GitLabInstanceStore) List(_ context.Context) ([]GitLabInstance, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	insts, err := s.load()
	if err != nil {
		return nil, err
	}
	sort.Slice(insts, func(i, j int) bool { return insts[i].Name < insts[j].Name })
	return insts, nil
}

// Put inserts or updates an instance. `ID` is required for updates;
// callers pass empty ID on first add and the store generates one.
func (s *GitLabInstanceStore) Put(_ context.Context, inst GitLabInstance) (GitLabInstance, error) {
	if err := validateInstance(inst); err != nil {
		return inst, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	insts, err := s.load()
	if err != nil {
		return inst, err
	}
	if inst.ID == "" {
		inst.ID = randomHex(8)
		inst.AddedAt = time.Now().UTC()
	}
	replaced := false
	for i, e := range insts {
		if e.ID == inst.ID {
			insts[i] = inst
			replaced = true
			break
		}
	}
	if !replaced {
		insts = append(insts, inst)
	}
	if err := s.save(insts); err != nil {
		return inst, err
	}
	return inst, nil
}

func (s *GitLabInstanceStore) Delete(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	insts, err := s.load()
	if err != nil {
		return err
	}
	out := insts[:0]
	for _, e := range insts {
		if e.ID != id {
			out = append(out, e)
		}
	}
	return s.save(out)
}

// Resolve returns one instance by id, name, or — if there is exactly one —
// the lone configured instance. Empty ref + multi-instance → error so the
// caller knows the user must disambiguate.
func (s *GitLabInstanceStore) Resolve(ctx context.Context, ref string) (*GitLabInstance, error) {
	insts, err := s.List(ctx)
	if err != nil {
		return nil, err
	}
	if len(insts) == 0 {
		return nil, errors.New("no gitlab instance configured")
	}
	if ref == "" {
		if len(insts) == 1 {
			cp := insts[0]
			return &cp, nil
		}
		return nil, fmt.Errorf("ambiguous gitlab instance — pass `instance=<id|name>` (have %d)", len(insts))
	}
	for _, e := range insts {
		if e.ID == ref || strings.EqualFold(e.Name, ref) {
			cp := e
			return &cp, nil
		}
	}
	return nil, fmt.Errorf("gitlab instance %q not found", ref)
}

func validateInstance(inst GitLabInstance) error {
	if strings.TrimSpace(inst.Name) == "" {
		return errors.New("gitlab instance: name required")
	}
	if !strings.HasPrefix(inst.BaseURL, "https://") {
		return errors.New("gitlab instance: baseUrl must be https://")
	}
	return nil
}

func (s *GitLabInstanceStore) load() ([]GitLabInstance, error) {
	b, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	if len(b) == 0 {
		return nil, nil
	}
	var insts []GitLabInstance
	if err := json.Unmarshal(b, &insts); err != nil {
		return nil, err
	}
	return insts, nil
}

func (s *GitLabInstanceStore) save(insts []GitLabInstance) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	b, err := json.MarshalIndent(insts, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		// Fall back to nanos — collisions become possible but never silent.
		return fmt.Sprintf("%016x", time.Now().UnixNano())[:n*2]
	}
	return hex.EncodeToString(b)
}
