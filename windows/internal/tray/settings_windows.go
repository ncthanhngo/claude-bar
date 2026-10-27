//go:build windows

package tray

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// settings are the tray's own preferences, in %APPDATA%\ClaudeSwap\tray.json
// next to csw's data. Missing file or field = default.
type settings struct {
	ReloadIDE     bool `json:"reloadIDE"`     // restart IDE Claude sessions after a switch
	SwitchDesktop bool `json:"switchDesktop"` // switch Claude Desktop's sign-in too
}

func settingsPath() string {
	return filepath.Join(os.Getenv("APPDATA"), "ClaudeSwap", "tray.json")
}

func loadSettings() settings {
	s := settings{ReloadIDE: true, SwitchDesktop: true}
	if data, err := os.ReadFile(settingsPath()); err == nil {
		_ = json.Unmarshal(data, &s)
	}
	return s
}

func saveSettings(s settings) error {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(settingsPath()), 0o700); err != nil {
		return err
	}
	return os.WriteFile(settingsPath(), data, 0o600)
}
