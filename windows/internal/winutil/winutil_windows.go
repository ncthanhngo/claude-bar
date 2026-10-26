//go:build windows

// Package winutil wraps the few Windows APIs the tray needs.
package winutil

import (
	"errors"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const (
	runKey   = `Software\Microsoft\Windows\CurrentVersion\Run`
	runValue = "ClaudeSwap"
)

// SingleInstance holds a per-session mutex; ok=false means another tray is
// already running.
func SingleInstance(name string) (ok bool, err error) {
	_, err = windows.CreateMutex(nil, false, windows.StringToUTF16Ptr(name))
	if errors.Is(err, windows.ERROR_ALREADY_EXISTS) {
		return false, nil
	}
	return err == nil, err
}

// AutostartEnabled reports whether the Run key points at this executable.
func AutostartEnabled() bool {
	k, err := registry.OpenKey(registry.CURRENT_USER, runKey, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer k.Close()
	v, _, err := k.GetStringValue(runValue)
	exe, _ := os.Executable()
	return err == nil && v == quote(exe)
}

// SetAutostart adds or removes the per-user Run entry.
func SetAutostart(on bool) error {
	k, _, err := registry.CreateKey(registry.CURRENT_USER, runKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	if !on {
		if err := k.DeleteValue(runValue); err != nil && !errors.Is(err, registry.ErrNotExist) {
			return err
		}
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	return k.SetStringValue(runValue, quote(exe))
}

func quote(s string) string { return `"` + s + `"` }

// Open hands a folder or URL to the shell.
func Open(target string) error {
	return windows.ShellExecute(0, nil, windows.StringToUTF16Ptr(target), nil, nil, windows.SW_SHOWNORMAL)
}

// LogsDir is where csw writes csw.log.
func LogsDir() string {
	dir, _ := os.UserCacheDir()
	return filepath.Join(dir, "ClaudeSwap", "logs")
}

// BesideExecutable returns name in the folder holding this program.
func BesideExecutable(name string) string {
	exe, _ := os.Executable()
	return filepath.Join(filepath.Dir(exe), name)
}
