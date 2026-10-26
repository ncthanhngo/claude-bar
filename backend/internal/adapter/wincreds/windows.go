//go:build windows

package wincreds

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"unsafe"

	"github.com/danieljoos/wincred"
	"golang.org/x/sys/windows"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
)

// NewLiveStore binds to the current user's Claude Code login.
func NewLiveStore() *LiveStore {
	return newLiveStore(
		filepath.Join(adapter.ClaudeConfigDir(), ".credentials.json"),
		func() bool { return credmanEnabled(os.Getenv, adapter.ClaudeConfigFile()) },
		winCredman{},
	)
}

// NewBackupStore keeps backups under %APPDATA%\ClaudeSwap\backups.
func NewBackupStore() *BackupStore {
	return newBackupStore(filepath.Join(adapter.WidgetDataDir(), "backups"), dpapiProtect, dpapiUnprotect)
}

type winCredman struct{}

func (winCredman) list(prefix string) ([]credEntry, error) {
	creds, err := wincred.FilteredList(prefix + "*")
	if err != nil {
		if err == wincred.ErrElementNotFound {
			return nil, nil
		}
		return nil, err
	}
	out := make([]credEntry, 0, len(creds))
	for _, c := range creds {
		out = append(out, credEntry{target: c.TargetName, blob: c.CredentialBlob})
	}
	return out, nil
}

// write updates the entry in place (keeping its user name and persistence),
// creating it only when asked: an existing entry that can't be read as a
// generic credential is an error, never a reason to add a second one.
func (winCredman) write(target string, blob []byte, create bool) error {
	g, err := wincred.GetGenericCredential(target)
	switch {
	case err == nil:
	case create && errors.Is(err, wincred.ErrElementNotFound):
		g = wincred.NewGenericCredential(target)
		g.Persist = wincred.PersistLocalMachine
	default:
		return fmt.Errorf("read Credential Manager entry %q: %w", target, err)
	}
	g.CredentialBlob = blob
	return g.Write()
}

func dpapiProtect(plain []byte) ([]byte, error) {
	return dpapi(plain, true)
}

func dpapiUnprotect(enc []byte) ([]byte, error) {
	return dpapi(enc, false)
}

// dpapi encrypts or decrypts for the current Windows user.
func dpapi(in []byte, protect bool) ([]byte, error) {
	if len(in) == 0 {
		return nil, nil
	}
	src := windows.DataBlob{Size: uint32(len(in)), Data: &in[0]}
	var dst windows.DataBlob
	var err error
	if protect {
		err = windows.CryptProtectData(&src, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &dst)
	} else {
		err = windows.CryptUnprotectData(&src, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &dst)
	}
	if err != nil {
		return nil, err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(dst.Data)))
	return append([]byte(nil), unsafe.Slice(dst.Data, dst.Size)...), nil
}
