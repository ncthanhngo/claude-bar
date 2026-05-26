// Package registry persists the widget registry as JSON on disk with
// atomic writes and 0600 perms.
package registry

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

// FileRegistry stores the Registry as a JSON file under ~/Library/Application Support.
type FileRegistry struct {
	path string
}

// New returns a FileRegistry at the default widget data path.
func New() *FileRegistry {
	return &FileRegistry{path: adapter.RegistryFile()}
}

// NewAt returns a FileRegistry at a custom path (tests).
func NewAt(path string) *FileRegistry { return &FileRegistry{path: path} }

// Load returns the on-disk registry, or an empty one if the file doesn't exist.
func (r *FileRegistry) Load(ctx context.Context) (*domain.Registry, error) {
	data, err := os.ReadFile(r.path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return domain.NewRegistry(), nil
		}
		return nil, err
	}
	var reg domain.Registry
	if err := json.Unmarshal(data, &reg); err != nil {
		return nil, err
	}
	if reg.Accounts == nil {
		reg.Accounts = map[int]*domain.Account{}
	}
	if reg.Sequence == nil {
		reg.Sequence = []int{}
	}
	// Normalize stale per-account MCP Enabled flags. The Settings UI only
	// exposes shared connectors now, so a per-account meta carrying
	// Enabled=true while a shared meta of the same service also exists is
	// always stale — usually an artefact of an iCloud restore from a Mac
	// running an older build that surfaced per-account configuration. The
	// gateway already treats shared as authoritative for tools/list, but
	// pruning the stale flag here keeps the on-disk registry honest so
	// downstream tools (debug dumps, cloud bundle pushes, future
	// migrations) don't have to re-derive the same invariant.
	if normalizeStaleMCPState(&reg) {
		if saveErr := r.Save(ctx, &reg); saveErr != nil {
			// Read still succeeds — normalize is best-effort.
			_ = saveErr
		}
	}
	return &reg, nil
}

// normalizeStaleMCPState clears per-account Enabled flags for services that
// also have a shared meta configured. Returns true iff at least one flag
// was flipped, signaling the caller should persist.
func normalizeStaleMCPState(reg *domain.Registry) bool {
	if len(reg.SharedMCPConnectors) == 0 {
		return false
	}
	changed := false
	for _, acc := range reg.Accounts {
		if acc == nil {
			continue
		}
		for svc, meta := range acc.MCPConnectors {
			if meta == nil || !meta.Enabled {
				continue
			}
			if _, hasShared := reg.SharedMCPConnectors[svc]; hasShared {
				meta.Enabled = false
				changed = true
			}
		}
	}
	return changed
}

// Save atomically writes the registry with 0600 perms.
func (r *FileRegistry) Save(ctx context.Context, reg *domain.Registry) error {
	if err := adapter.EnsureDataDir(); err != nil {
		return err
	}
	reg.LastUpdated = time.Now().UTC()
	data, err := json.MarshalIndent(reg, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(r.path)
	tmp, err := os.CreateTemp(dir, "registry-*.tmp")
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
	return os.Rename(tmpName, r.path)
}
