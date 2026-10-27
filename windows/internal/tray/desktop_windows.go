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

// Claude Desktop keeps its claude.ai sign-in in its Electron profile, apart
// from Claude Code's login. To switch it too, Claude Swap keeps one copy of
// the sign-in parts of that profile per account (DPAPI-encrypted, like the
// saved Claude Code logins) and swaps them while Desktop is closed. Settings
// (claude_desktop_config.json, config.json, Preferences) are shared and
// never touched.

// desktopSessionParts are the profile entries that hold the sign-in,
// relative to the data folder.
var desktopSessionParts = []string{
	`Network\Cookies`, `Network\Cookies-journal`,
	`Local Storage`, `Session Storage`, `IndexedDB`, `WebStorage`,
}

// claudeDesktop is an installed Claude Desktop.
type claudeDesktop struct {
	dataDir string // ...\Roaming\Claude
	aumid   string // MSIX app id for relaunch; "" for a non-store install
	exe     string // non-store install's Claude.exe
}

// findDesktop locates Claude Desktop: the Microsoft Store (MSIX) build keeps
// its data under Packages\<family>\LocalCache; the classic installer under
// %APPDATA%\Claude.
func findDesktop() (*claudeDesktop, bool) {
	pkgs, _ := filepath.Glob(filepath.Join(os.Getenv("LOCALAPPDATA"), "Packages", "Claude_*"))
	for _, p := range pkgs {
		data := filepath.Join(p, "LocalCache", "Roaming", "Claude")
		if isDir(data) {
			return &claudeDesktop{dataDir: data, aumid: filepath.Base(p) + "!Claude"}, true
		}
	}
	data := filepath.Join(os.Getenv("APPDATA"), "Claude")
	exe := filepath.Join(os.Getenv("LOCALAPPDATA"), "AnthropicClaude", "claude.exe")
	if isDir(data) {
		return &claudeDesktop{dataDir: data, exe: exe}, true
	}
	return nil, false
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
	procPostMessageW             = user32.NewProc("PostMessageW")
)

// quit closes Desktop: a polite WM_CLOSE to its windows first (it may only
// hide to the tray), then ends whatever is left. Its profile files are free
// once every process is gone.
func (d *claudeDesktop) quit() error {
	pids := d.pids()
	if len(pids) == 0 {
		return nil
	}
	own := map[uint32]bool{}
	for _, p := range pids {
		own[p] = true
	}
	cb := windows.NewCallback(func(hwnd, _ uintptr) uintptr {
		var pid uint32
		procGetWindowThreadProcessId.Call(hwnd, uintptr(unsafe.Pointer(&pid)))
		if own[pid] {
			procPostMessageW.Call(hwnd, 0x0010, 0, 0) // WM_CLOSE
		}
		return 1
	})
	procEnumWindows.Call(cb, 0)
	if d.waitGone(3 * time.Second) {
		return nil
	}
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
	if err := zw.Close(); err != nil {
		return nil, err
	}
	if files == 0 {
		return nil, errors.New("Claude Desktop has no saved sign-in yet")
	}
	return dpapiProtect(buf.Bytes())
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
	for _, part := range desktopSessionParts {
		if err := os.RemoveAll(filepath.Join(d.dataDir, part)); err != nil {
			return fmt.Errorf("clear Claude Desktop %s: %w", part, err)
		}
	}
	for _, f := range zr.File {
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

// desktopOwner is the identity key of the account Desktop is signed in to,
// as far as Claude Swap knows ("" = unknown).
func desktopOwner() string {
	var st struct {
		Owner string `json:"owner"`
	}
	data, _ := os.ReadFile(filepath.Join(desktopStoreDir(), "state.json"))
	_ = json.Unmarshal(data, &st)
	return st.Owner
}

func setDesktopOwner(key string) {
	_ = os.MkdirAll(desktopStoreDir(), 0o700)
	data, _ := json.Marshal(map[string]string{"owner": key})
	_ = os.WriteFile(filepath.Join(desktopStoreDir(), "state.json"), data, 0o600)
}
