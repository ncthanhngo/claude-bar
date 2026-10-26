package wincreds

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// credman is the Windows Credential Manager surface the live store needs.
type credman interface {
	list(prefix string) ([]credEntry, error)
	// write replaces target's blob; create=false means the entry must
	// already exist (never add a second one next to Claude Code's).
	write(target string, blob []byte, create bool) error
}

// LiveStore reads and writes the login Claude Code itself uses: an entry in
// Windows Credential Manager when Claude Code is on that backend, otherwise
// <claude config dir>\.credentials.json. Writes go wherever the current
// login lives and are read back to prove Claude Code will see them.
type LiveStore struct {
	credsFile  string
	useCredman func() bool
	cm         credman // nil when Credential Manager is unavailable
}

func newLiveStore(credsFile string, useCredman func() bool, cm credman) *LiveStore {
	return &LiveStore{credsFile: credsFile, useCredman: useCredman, cm: cm}
}

type liveLocation struct {
	credman bool
	target  string
	enc     blobEncoding
}

// locate finds the live login. With Credential Manager enabled, Claude Code
// may still fall back to the file (e.g. a login too large for an entry), so
// when both hold a login the newer one (later expiresAt) is the live one.
// ok=false means nobody is logged in.
func (s *LiveStore) locate() (loc liveLocation, blob string, ok bool, err error) {
	var cm *credEntry
	var cmText string
	var cmEnc blobEncoding
	if s.cm != nil && s.useCredman() {
		entries, err := s.cm.list(credmanTargetPrefix)
		if err != nil {
			return loc, "", false, fmt.Errorf("list Credential Manager: %w", err)
		}
		if e, found := pickCredman(entries); found {
			cm = &e
			cmText, cmEnc, _ = decodeBlob(e.blob)
		}
	}
	data, err := os.ReadFile(s.credsFile)
	fileOK := err == nil
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return loc, "", false, err
	}
	switch {
	case cm != nil && (!fileOK || expiresAt(cmText) >= expiresAt(string(data))):
		return liveLocation{credman: true, target: cm.target, enc: cmEnc}, cmText, true, nil
	case fileOK:
		return liveLocation{}, string(data), true, nil
	default:
		return liveLocation{}, "", false, nil
	}
}

// expiresAt is the login's access-token expiry, 0 when unreadable.
func expiresAt(blob string) int64 {
	p, err := domain.CredentialBlob(blob).Extract()
	if err != nil {
		return 0
	}
	return p.ExpiresAt
}

// Read returns the live credential blob, or "" if not logged in.
func (s *LiveStore) Read(context.Context) (domain.CredentialBlob, error) {
	_, blob, _, err := s.locate()
	return domain.CredentialBlob(blob), err
}

// Write replaces the live login where Claude Code currently keeps it.
func (s *LiveStore) Write(ctx context.Context, blob domain.CredentialBlob) error {
	loc, _, ok, err := s.locate()
	if err != nil {
		return err
	}
	create := false
	if !ok && s.cm != nil && s.useCredman() {
		loc = liveLocation{credman: true, target: defaultCredmanTarget, enc: encUTF8}
		create = true
	}
	if loc.credman {
		data := encodeBlob(string(blob), loc.enc)
		if len(data) > maxCredmanBlob {
			return fmt.Errorf("login is %d bytes, over Credential Manager's %d-byte limit", len(data), maxCredmanBlob)
		}
		err = s.cm.write(loc.target, data, create)
	} else {
		err = writeFileAtomic(s.credsFile, []byte(blob))
	}
	if err != nil {
		return err
	}
	if got, err := s.Read(ctx); err != nil || got != blob {
		return fmt.Errorf("live credential did not read back after write (credman=%v)", loc.credman)
	}
	return nil
}

// writeFileAtomic writes via a temp file in the same folder and renames it
// over the target, so a reader never sees a half-written file.
func writeFileAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return adapter.ReplaceFile(tmp.Name(), path)
}
