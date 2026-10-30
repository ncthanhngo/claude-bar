//go:build windows

package tray

import (
	"bytes"
	"encoding/json"
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
	config := func() map[string]any {
		var cfg map[string]any
		if err := json.Unmarshal([]byte(read("config.json")), &cfg); err != nil {
			t.Fatal(err)
		}
		return cfg
	}

	// Account A signed in.
	write(`Network\Cookies`, "cookies-A")
	write(`Local Storage\leveldb\000003.log`, "ls-A")
	write(`claude_desktop_config.json`, "mcp-config")
	write(`config.json`, `{"locale":"en-US","oauth:tokenCache":"tok-A","lastKnownAccountUuid":"uuid-A"}`)
	if got := d.accountUUID(); got != "uuid-A" {
		t.Fatalf("accountUUID = %q", got)
	}
	saveA, err := d.capture()
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(saveA, []byte("cookies-A")) || bytes.Contains(saveA, []byte("tok-A")) {
		t.Fatal("saved sign-in is not encrypted")
	}

	// Account B signs in (V2 token cache only, an IndexedDB A did not have)
	// and the user changes a setting.
	write(`Network\Cookies`, "cookies-B")
	write(`Local Storage\leveldb\000003.log`, "ls-B")
	write(`IndexedDB\https_claude.ai_0.indexeddb.leveldb\LOG`, "idb-B")
	write(`claude_desktop_config.json`, "mcp-config-edited")
	write(`config.json`, `{"locale":"vi-VN","oauth:tokenCacheV2":"tok-B","lastKnownAccountUuid":"uuid-B"}`)

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
		t.Fatalf("MCP config was touched: %q", got)
	}
	cfg := config()
	if cfg["oauth:tokenCache"] != "tok-A" || cfg["lastKnownAccountUuid"] != "uuid-A" {
		t.Fatalf("sign-in keys not restored: %v", cfg)
	}
	if _, ok := cfg["oauth:tokenCacheV2"]; ok {
		t.Fatalf("B's token cache survived the restore: %v", cfg)
	}
	if cfg["locale"] != "vi-VN" {
		t.Fatalf("other settings were touched: %v", cfg)
	}
	if got := d.accountUUID(); got != "uuid-A" {
		t.Fatalf("accountUUID after restore = %q", got)
	}
}

func TestDesktopCaptureNeedsASignIn(t *testing.T) {
	dir := t.TempDir()
	d := &claudeDesktop{dataDir: dir}
	if _, err := d.capture(); err == nil {
		t.Fatal("capture of an empty profile should fail")
	}
	// Web files but signed out (no token cache): still nothing to save.
	_ = os.MkdirAll(filepath.Join(dir, "Network"), 0o700)
	_ = os.WriteFile(filepath.Join(dir, `Network\Cookies`), []byte("c"), 0o600)
	_ = os.WriteFile(filepath.Join(dir, "config.json"), []byte(`{"lastKnownAccountUuid":"u"}`), 0o600)
	if _, err := d.capture(); err == nil {
		t.Fatal("capture of a signed-out Desktop should fail")
	}
	if d.accountUUID() != "" {
		t.Fatal("signed-out Desktop should report no account")
	}
}

func TestFindDesktopPrefersMovedDataFolder(t *testing.T) {
	local := t.TempDir()
	t.Setenv("LOCALAPPDATA", local)
	t.Setenv("APPDATA", t.TempDir())
	old := filepath.Join(local, "Packages", "Claude_abc", "LocalCache", "Roaming", "Claude")
	moved := filepath.Join(local, "Claude-Data", "claude_abc")
	for _, p := range []string{old, moved} {
		if err := os.MkdirAll(p, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	_ = os.WriteFile(filepath.Join(old, ".user-data-left.claude_abc"), []byte("{}"), 0o600)
	_ = os.WriteFile(filepath.Join(moved, "Local State"), []byte("{}"), 0o600)

	d, ok := findDesktop()
	if !ok || d.dataDir != moved || d.aumid != "Claude_abc!Claude" {
		t.Fatalf("findDesktop = %+v, %v; want data in %s", d, ok, moved)
	}
}

func TestDesktopForgetSignInKeepsSettings(t *testing.T) {
	dir := t.TempDir()
	d := &claudeDesktop{dataDir: dir}
	_ = os.MkdirAll(filepath.Join(dir, "Network"), 0o700)
	_ = os.WriteFile(filepath.Join(dir, `Network\Cookies`), []byte("c"), 0o600)
	_ = os.WriteFile(filepath.Join(dir, "claude_desktop_config.json"), []byte("mcp"), 0o600)
	_ = os.WriteFile(filepath.Join(dir, "config.json"),
		[]byte(`{"locale":"vi-VN","oauth:tokenCache":"t","oauth:tokenCacheV2":"t2","lastKnownAccountUuid":"u"}`), 0o600)

	if err := d.forgetSignIn(); err != nil {
		t.Fatal(err)
	}
	if d.accountUUID() != "" {
		t.Fatal("still signed in")
	}
	if _, err := os.Stat(filepath.Join(dir, `Network\Cookies`)); !os.IsNotExist(err) {
		t.Fatal("cookies survived")
	}
	var cfg map[string]any
	b, _ := os.ReadFile(filepath.Join(dir, "config.json"))
	_ = json.Unmarshal(b, &cfg)
	if cfg["locale"] != "vi-VN" || len(cfg) != 1 {
		t.Fatalf("config after forget = %v", cfg)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "claude_desktop_config.json")); string(b) != "mcp" {
		t.Fatal("MCP config touched")
	}
}
