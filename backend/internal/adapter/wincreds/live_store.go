package wincreds

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// credman is the Windows Credential Manager surface the live store needs.
type credman interface {
	list(prefix string) ([]credEntry, error)
	write(target string, blob []byte) error
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

// locate finds the live login: Credential Manager first when enabled, then
// the file. ok=false means nobody is logged in.
func (s *LiveStore) locate() (loc liveLocation, blob string, ok bool, err error) {
	if s.cm != nil && s.useCredman() {
		entries, err := s.cm.list(credmanTargetPrefix)
		if err != nil {
			return loc, "", false, fmt.Errorf("list Credential Manager: %w", err)
		}
		if e, found := pickCredman(entries); found {
			text, enc, _ := decodeBlob(e.blob)
			return liveLocation{credman: true, target: e.target, enc: enc}, text, true, nil
		}
	}
	data, err := os.ReadFile(s.credsFile)
	if errors.Is(err, fs.ErrNotExist) {
		return liveLocation{}, "", false, nil
	}
	if err != nil {
		return loc, "", false, err
	}
	return liveLocation{}, string(data), true, nil
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
	if !ok && s.cm != nil && s.useCredman() {
		loc = liveLocation{credman: true, target: defaultCredmanTarget, enc: encUTF8}
	}
	if loc.credman {
		err = s.cm.write(loc.target, encodeBlob(string(blob), loc.enc))
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
	return os.Rename(tmp.Name(), path)
}
