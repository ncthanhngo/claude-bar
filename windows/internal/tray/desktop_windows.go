//go:build windows

package tray

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"

	"github.com/soi/claude-swap-widget/windows/internal/cswclient"
)

// Claude Desktop keeps its sign-in in its Electron profile, apart from
// Claude Code's login: OAuth tokens in config.json (encrypted by Electron's
// safeStorage) plus the claude.ai web session (cookies, storage). To switch
// it too, Claude Swap keeps one copy of those parts per account
// (DPAPI-encrypted, like the saved Claude Code logins) and swaps them while
// Desktop is closed. Everything else — the rest of config.json,
// claude_desktop_config.json (MCP), Preferences, Cowork data — is shared
// and never touched.

// desktopSessionParts are the profile entries that hold the web session,
// relative to the data folder.
var desktopSessionParts = []string{
	`Network\Cookies`, `Network\Cookies-journal`,
	`Local Storage`, `Session Storage`, `IndexedDB`, `WebStorage`,
}

// desktopConfigKeys are the config.json entries that are the sign-in.
var desktopConfigKeys = []string{"oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"}

// desktopConfigEntry is where captured config keys travel inside a save.
const desktopConfigEntry = "claude-swap/config-keys.json"

// claudeDesktop is an installed Claude Desktop.
type claudeDesktop struct {
	dataDir string // the profile folder Desktop really uses
	aumid   string // MSIX app id for relaunch; "" for a non-store install
	exe     string // non-store install's Claude.exe
}

// findDesktop locates Claude Desktop and the profile it really uses.
// Current Store (MSIX) builds move their data out of the package to
// %LOCALAPPDATA%\Claude-Data\claude_<publisher> on first run and leave a
// ".user-data-left.*" marker in the old Packages\...\LocalCache folder;
// older ones keep it there; the classic installer uses %APPDATA%\Claude.
func findDesktop() (*claudeDesktop, bool) {
	local := os.Getenv("LOCALAPPDATA")
	aumid := ""
	if pkgs, _ := filepath.Glob(filepath.Join(local, "Packages", "Claude_*")); len(pkgs) > 0 {
		aumid = filepath.Base(pkgs[0]) + "!Claude"
	}
	exe := filepath.Join(local, "AnthropicClaude", "claude.exe")

	var best string
	var bestTime time.Time
	dirs, _ := filepath.Glob(filepath.Join(local, "Claude-Data", "claude_*"))
	for _, dir := range dirs {
		if st, err := os.Stat(filepath.Join(dir, "Local State")); err == nil && st.ModTime().After(bestTime) {
			best, bestTime = dir, st.ModTime()
		}
	}
	if best == "" && aumid != "" {
		old := filepath.Join(local, "Packages", strings.TrimSuffix(aumid, "!Claude"), "LocalCache", "Roaming", "Claude")
		if left, _ := filepath.Glob(filepath.Join(old, ".user-data-left*")); len(left) == 0 && isDir(old) {
			best = old
		}
	}
	if best == "" && isDir(filepath.Join(os.Getenv("APPDATA"), "Claude")) {
		best = filepath.Join(os.Getenv("APPDATA"), "Claude")
	}
	if best == "" {
		return nil, false
	}
	if aumid != "" {
		return &claudeDesktop{dataDir: best, aumid: aumid}, true
	}
	return &claudeDesktop{dataDir: best, exe: exe}, true
}

// readConfig reads Desktop's config.json as raw JSON values.
func (d *claudeDesktop) readConfig() (map[string]json.RawMessage, error) {
	data, err := os.ReadFile(filepath.Join(d.dataDir, "config.json"))
	if os.IsNotExist(err) {
		return map[string]json.RawMessage{}, nil
	}
	if err != nil {
		return nil, err
	}
	cfg := map[string]json.RawMessage{}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("read Claude Desktop config.json: %w", err)
	}
	return cfg, nil
}

// accountUUID is the account Desktop is signed in to ("" if none or unknown).
func (d *claudeDesktop) accountUUID() string {
	cfg, err := d.readConfig()
	if err != nil {
		return ""
	}
	var uuid string
	_ = json.Unmarshal(cfg["lastKnownAccountUuid"], &uuid)
	if len(cfg["oauth:tokenCache"]) == 0 && len(cfg["oauth:tokenCacheV2"]) == 0 {
		return "" // signed out
	}
	return uuid
}

func isDir(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

// pids lists Claude Desktop's processes (not Claude Code's claude.exe).
func (d *claudeDesktop) pids() []uint32 {
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil
	}
	defer windows.CloseHandle(snap)
	var out []uint32
	e := windows.ProcessEntry32{Size: uint32(unsafe.Sizeof(windows.ProcessEntry32{}))}
	for err = windows.Process32First(snap, &e); err == nil; err = windows.Process32Next(snap, &e) {
		if !strings.EqualFold(windows.UTF16ToString(e.ExeFile[:]), "claude.exe") {
			continue
		}
		path := strings.ToLower(processPath(e.ProcessID))
		if strings.Contains(path, `\windowsapps\claude_`) || strings.Contains(path, `\anthropicclaude\`) {
			out = append(out, e.ProcessID)
		}
	}
	return out
}

func processPath(pid uint32) string {
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return ""
	}
	defer windows.CloseHandle(h)
	buf := make([]uint16, windows.MAX_LONG_PATH)
	n := uint32(len(buf))
	if windows.QueryFullProcessImageName(h, 0, &buf[0], &n) != nil {
		return ""
	}
	return windows.UTF16ToString(buf[:n])
}

func (d *claudeDesktop) running() bool { return len(d.pids()) > 0 }

var (
	procEnumWindows              = user32.NewProc("EnumWindows")
	procGetWindowThreadProcessId = user32.NewProc("GetWindowThreadProcessId")
	procSendMessageTimeoutW      = user32.NewProc("SendMessageTimeoutW")
)

// endSessionCallback is shared: windows.NewCallback slots are never freed.
var (
	endSessionPids map[uint32]bool
	endSessionWnds []uintptr
	endSessionCB   = windows.NewCallback(func(hwnd, _ uintptr) uintptr {
		var pid uint32
		procGetWindowThreadProcessId.Call(hwnd, uintptr(unsafe.Pointer(&pid)))
		if endSessionPids[pid] {
			endSessionWnds = append(endSessionWnds, hwnd)
		}
		return 1
	})
)

// quit closes Desktop the way Windows does when an app must close for an
// update (WM_QUERYENDSESSION + WM_ENDSESSION with ENDSESSION_CLOSEAPP):
// Electron then shuts down cleanly and writes its cookies first. WM_CLOSE
// only hides Desktop to the tray, and killing it loses a sign-in made in
// the last ~30 s (Chromium writes cookies in batches). Ending the processes
// is the fallback when Desktop does not respond.
func (d *claudeDesktop) quit() error {
	pids := d.pids()
	if len(pids) == 0 {
		return nil
	}
	endSessionPids = map[uint32]bool{}
	for _, p := range pids {
		endSessionPids[p] = true
	}
	endSessionWnds = nil
	procEnumWindows.Call(endSessionCB, 0)
	const (
		wmQueryEndSession  = 0x0011
		wmEndSession       = 0x0016
		endSessionCloseApp = 0x1
		smtoAbortIfHung    = 0x2
	)
	var res uintptr
	for _, h := range endSessionWnds {
		procSendMessageTimeoutW.Call(h, wmQueryEndSession, 0, endSessionCloseApp, smtoAbortIfHung, 3000, uintptr(unsafe.Pointer(&res)))
	}
	for _, h := range endSessionWnds {
		procSendMessageTimeoutW.Call(h, wmEndSession, 1, endSessionCloseApp, smtoAbortIfHung, 3000, uintptr(unsafe.Pointer(&res)))
	}
	if d.waitGone(15 * time.Second) {
		logf("desktop quit: closed cleanly")
		return nil
	}
	logf("desktop quit: did not close in time, ending its processes")
	for _, p := range d.pids() {
		if h, err := windows.OpenProcess(windows.PROCESS_TERMINATE, false, p); err == nil {
			_ = windows.TerminateProcess(h, 0)
			windows.CloseHandle(h)
		}
	}
	if !d.waitGone(10 * time.Second) {
		return errors.New("Claude Desktop did not close")
	}
	return nil
}

func (d *claudeDesktop) waitGone(limit time.Duration) bool {
	for end := time.Now().Add(limit); time.Now().Before(end); time.Sleep(200 * time.Millisecond) {
		if !d.running() {
			time.Sleep(500 * time.Millisecond) // let file handles close
			return true
		}
	}
	return false
}

func (d *claudeDesktop) launch() error {
	if d.aumid != "" {
		return exec.Command("explorer.exe", `shell:AppsFolder\`+d.aumid).Start()
	}
	return exec.Command(d.exe).Start()
}

// capture zips the sign-in parts of the profile and encrypts them for the
// current Windows user. Desktop must be closed.
func (d *claudeDesktop) capture() ([]byte, error) {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	files := 0
	for _, part := range desktopSessionParts {
		root := filepath.Join(d.dataDir, part)
		err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				if os.IsNotExist(err) {
					return nil
				}
				return err
			}
			if info.IsDir() {
				return nil
			}
			rel, _ := filepath.Rel(d.dataDir, path)
			w, err := zw.Create(filepath.ToSlash(rel))
			if err != nil {
				return err
			}
			f, err := os.Open(path)
			if err != nil {
				return err
			}
			defer f.Close()
			_, err = io.Copy(w, f)
			files++
			return err
		})
		if err != nil {
			return nil, fmt.Errorf("read Claude Desktop %s: %w", part, err)
		}
	}
	cfg, err := d.readConfig()
	if err != nil {
		return nil, err
	}
	keys := map[string]json.RawMessage{}
	for _, k := range desktopConfigKeys {
		if v, ok := cfg[k]; ok {
			keys[k] = v
		}
	}
	if len(keys["oauth:tokenCache"]) == 0 && len(keys["oauth:tokenCacheV2"]) == 0 {
		return nil, errors.New("Claude Desktop is not signed in — sign in to it first")
	}
	kw, err := zw.Create(desktopConfigEntry)
	if err != nil {
		return nil, err
	}
	if err := json.NewEncoder(kw).Encode(keys); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	if files == 0 {
		return nil, errors.New("Claude Desktop's web session files were not found")
	}
	return dpapiProtect(buf.Bytes())
}

// forgetSignIn removes the sign-in from this PC only, so Desktop opens at
// its sign-in screen. Unlike Desktop's own "Log out" it does not end the
// session at Anthropic, so a saved copy of it keeps working. Desktop must
// be closed.
func (d *claudeDesktop) forgetSignIn() error {
	if err := d.writeConfigKeys(nil); err != nil {
		return err
	}
	for _, part := range desktopSessionParts {
		if err := os.RemoveAll(filepath.Join(d.dataDir, part)); err != nil {
			return fmt.Errorf("clear Claude Desktop %s: %w", part, err)
		}
	}
	return nil
}

// writeConfigKeys sets the sign-in keys of config.json to keys (removing
// those keys absent from it) and leaves every other setting as it is.
func (d *claudeDesktop) writeConfigKeys(keys map[string]json.RawMessage) error {
	cfg, err := d.readConfig()
	if err != nil {
		return err
	}
	for _, k := range desktopConfigKeys {
		if v, ok := keys[k]; ok {
			cfg[k] = v
		} else {
			delete(cfg, k)
		}
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	path := filepath.Join(d.dataDir, "config.json")
	if err := os.WriteFile(path+".claude-swap.tmp", data, 0o600); err != nil {
		return err
	}
	return os.Rename(path+".claude-swap.tmp", path)
}

// restore replaces the sign-in parts of the profile with a captured copy.
// Desktop must be closed.
func (d *claudeDesktop) restore(blob []byte) error {
	raw, err := dpapiUnprotect(blob)
	if err != nil {
		return fmt.Errorf("decrypt saved Desktop sign-in: %w", err)
	}
	zr, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if err != nil {
		return err
	}
	var keys map[string]json.RawMessage
	for _, f := range zr.File {
		if f.Name != desktopConfigEntry {
			continue
		}
		r, err := f.Open()
		if err != nil {
			return err
		}
		err = json.NewDecoder(r).Decode(&keys)
		r.Close()
		if err != nil {
			return fmt.Errorf("saved Desktop sign-in: %w", err)
		}
	}
	if keys == nil {
		// Saved by an older Claude Swap without config keys: it never held
		// the sign-in, so restoring it would only sign Desktop out.
		return errors.New("this saved Desktop sign-in is from an older Claude Swap — save it again")
	}
	if err := d.writeConfigKeys(keys); err != nil {
		return fmt.Errorf("write Claude Desktop config.json: %w", err)
	}
	for _, part := range desktopSessionParts {
		if err := os.RemoveAll(filepath.Join(d.dataDir, part)); err != nil {
			return fmt.Errorf("clear Claude Desktop %s: %w", part, err)
		}
	}
	for _, f := range zr.File {
		if f.Name == desktopConfigEntry {
			continue
		}
		dst := filepath.Join(d.dataDir, filepath.FromSlash(f.Name))
		if !strings.HasPrefix(dst, d.dataDir+string(os.PathSeparator)) {
			continue // never write outside the profile
		}
		if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
			return err
		}
		r, err := f.Open()
		if err != nil {
			return err
		}
		data, err := io.ReadAll(r)
		r.Close()
		if err != nil {
			return err
		}
		if err := os.WriteFile(dst, data, 0o600); err != nil {
			return err
		}
	}
	return nil
}

func dpapiProtect(data []byte) ([]byte, error) {
	in := windows.DataBlob{Size: uint32(len(data)), Data: &data[0]}
	var out windows.DataBlob
	if err := windows.CryptProtectData(&in, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out); err != nil {
		return nil, err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	return append([]byte(nil), unsafe.Slice(out.Data, out.Size)...), nil
}

func dpapiUnprotect(data []byte) ([]byte, error) {
	if len(data) == 0 {
		return nil, errors.New("empty")
	}
	in := windows.DataBlob{Size: uint32(len(data)), Data: &data[0]}
	var out windows.DataBlob
	if err := windows.CryptUnprotectData(&in, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out); err != nil {
		return nil, err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	return append([]byte(nil), unsafe.Slice(out.Data, out.Size)...), nil
}

// Saved Desktop sign-ins live in %APPDATA%\ClaudeSwap\desktop, one file per
// account identity, plus which account Desktop is signed in to now.

func desktopStoreDir() string {
	return filepath.Join(os.Getenv("APPDATA"), "ClaudeSwap", "desktop")
}

func desktopSavePath(acc cswclient.Account) string {
	return filepath.Join(desktopStoreDir(), identityKey(acc)+".bin")
}

func readDesktopSave(acc cswclient.Account) ([]byte, error) {
	return os.ReadFile(desktopSavePath(acc))
}

func hasDesktopSave(acc cswclient.Account) bool {
	_, err := os.Stat(desktopSavePath(acc))
	return err == nil
}

func writeDesktopSave(acc cswclient.Account, blob []byte) error {
	if err := os.MkdirAll(desktopStoreDir(), 0o700); err != nil {
		return err
	}
	tmp := desktopSavePath(acc) + ".tmp"
	if err := os.WriteFile(tmp, blob, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, desktopSavePath(acc))
}

// desktopIndex maps each saved Desktop sign-in (by identity key) to the
// Claude account UUID Desktop reported when it was saved. Desktop's own
// lastKnownAccountUuid then tells which saved account it is on now — no
// guessing, and a sign-in is never stored under the wrong account.
func desktopIndex() map[string]string {
	idx := map[string]string{}
	data, _ := os.ReadFile(filepath.Join(desktopStoreDir(), "index.json"))
	_ = json.Unmarshal(data, &idx)
	return idx
}

func setDesktopIndex(key, uuid string) {
	idx := desktopIndex()
	if uuid == "" {
		delete(idx, key)
	} else {
		idx[key] = uuid
	}
	_ = os.MkdirAll(desktopStoreDir(), 0o700)
	data, _ := json.MarshalIndent(idx, "", "  ")
	_ = os.WriteFile(filepath.Join(desktopStoreDir(), "index.json"), data, 0o600)
}

// desktopKeyFor is the identity key whose saved sign-in is Desktop account
// uuid ("" if none).
func desktopKeyFor(uuid string) string {
	if uuid == "" {
		return ""
	}
	for key, u := range desktopIndex() {
		if u == uuid {
			return key
		}
	}
	return ""
}
