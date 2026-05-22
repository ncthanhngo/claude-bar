package briefingstore

import (
	"encoding/json"
	"errors"
	"os"

	"github.com/soi/claude-swap-widget/backend/internal/usecase/briefing"
)

// ConfigStore persists the schedule + lastBriefingDate pointer.
type ConfigStore struct {
	path string
}

// NewConfigStore returns a ConfigStore at the canonical config path.
func NewConfigStore() (*ConfigStore, error) {
	p, err := briefing.ConfigFile()
	if err != nil {
		return nil, err
	}
	return &ConfigStore{path: p}, nil
}

// configFileShape is the on-disk JSON; embeds Schedule + run pointer.
type configFileShape struct {
	briefing.Schedule
	LastBriefingDate string `json:"lastBriefingDate"` // YYYY-MM-DD
}

// Load returns the persisted schedule. If the file is absent, returns the
// default config (08:33 T2-T6 Asia/Saigon, enabled).
func (c *ConfigStore) Load() (briefing.Schedule, string, error) {
	data, err := os.ReadFile(c.path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return briefing.DefaultSchedule(), "", nil
		}
		return briefing.Schedule{}, "", err
	}
	var f configFileShape
	if err := json.Unmarshal(data, &f); err != nil {
		return briefing.Schedule{}, "", err
	}
	if f.SchemaVersion == 0 {
		f.SchemaVersion = briefing.SchemaVersion
	}
	return f.Schedule, f.LastBriefingDate, nil
}

// Save writes the schedule + lastBriefingDate atomically.
func (c *ConfigStore) Save(s briefing.Schedule, lastBriefingDate string) error {
	s.SchemaVersion = briefing.SchemaVersion
	f := configFileShape{Schedule: s, LastBriefingDate: lastBriefingDate}
	data, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return err
	}
	tmp := c.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, c.path)
}
