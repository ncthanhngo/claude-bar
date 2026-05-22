package briefing

import (
	"os"
	"path/filepath"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
)

// briefingsDir is the on-disk folder holding {YYYY-MM-DD}.json + config + lock.
//
// Layout under ~/Library/Application Support/claude-swap-widget/briefings/:
//
//	2026-05-21.json
//	2026-05-20.json
//	briefing-config.json
//	.run.lock
func briefingsDir() string {
	return filepath.Join(adapter.WidgetDataDir(), "briefings")
}

// Dir returns the briefings directory, creating it (0700) if missing.
func Dir() (string, error) {
	d := briefingsDir()
	if err := os.MkdirAll(d, 0o700); err != nil {
		return "", err
	}
	return d, nil
}

// File returns the per-day briefing JSON path. date format: YYYY-MM-DD.
func File(date string) (string, error) {
	d, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, date+".json"), nil
}

// ConfigFile returns the schedule config path.
func ConfigFile() (string, error) {
	d, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "briefing-config.json"), nil
}

// RunLockFile returns the cross-process run lock path.
func RunLockFile() (string, error) {
	d, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, ".run.lock"), nil
}
