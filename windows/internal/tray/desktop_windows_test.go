//go:build windows

package tray

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestDesktopCaptureRestoreSwapsOnlySignIn(t *testing.T) {
	dir := t.TempDir()
	d := &claudeDesktop{dataDir: dir}
	write := func(rel, body string) {
		p := filepath.Join(dir, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	read := func(rel string) string {
		b, err := os.ReadFile(filepath.Join(dir, rel))
		if err != nil {
			return "<missing>"
		}
		return string(b)
	}

	// Account A signed in.
	write(`Network\Cookies`, "cookies-A")
	write(`Local Storage\leveldb\000003.log`, "ls-A")
	write(`claude_desktop_config.json`, "mcp-config")
	saveA, err := d.capture()
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(saveA, []byte("cookies-A")) {
		t.Fatal("saved sign-in is not encrypted")
	}

	// Account B signs in; it has an IndexedDB A did not.
	write(`Network\Cookies`, "cookies-B")
	write(`Local Storage\leveldb\000003.log`, "ls-B")
	write(`IndexedDB\https_claude.ai_0.indexeddb.leveldb\LOG`, "idb-B")
	write(`claude_desktop_config.json`, "mcp-config-edited")

	if err := d.restore(saveA); err != nil {
		t.Fatal(err)
	}
	if got := read(`Network\Cookies`); got != "cookies-A" {
		t.Fatalf("cookies = %q", got)
	}
	if got := read(`Local Storage\leveldb\000003.log`); got != "ls-A" {
		t.Fatalf("local storage = %q", got)
	}
	if got := read(`IndexedDB\https_claude.ai_0.indexeddb.leveldb\LOG`); got != "<missing>" {
		t.Fatalf("B's IndexedDB survived the restore: %q", got)
	}
	if got := read(`claude_desktop_config.json`); got != "mcp-config-edited" {
		t.Fatalf("settings were touched: %q", got)
	}
}

func TestDesktopCaptureNeedsASignIn(t *testing.T) {
	if _, err := (&claudeDesktop{dataDir: t.TempDir()}).capture(); err == nil {
		t.Fatal("capture of an empty profile should fail")
	}
}
