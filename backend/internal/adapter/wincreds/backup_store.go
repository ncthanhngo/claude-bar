package wincreds

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// BackupStore keeps each account's credential in its own file, encrypted
// for the current Windows user (DPAPI). Files sit in the app data folder;
// the email is hashed so file names don't reveal it.
type BackupStore struct {
	dir       string
	protect   func([]byte) ([]byte, error)
	unprotect func([]byte) ([]byte, error)
}

func newBackupStore(dir string, protect, unprotect func([]byte) ([]byte, error)) *BackupStore {
	return &BackupStore{dir: dir, protect: protect, unprotect: unprotect}
}

func (s *BackupStore) path(num int, email string) string {
	sum := sha256.Sum256([]byte(strings.ToLower(strings.TrimSpace(email))))
	return filepath.Join(s.dir, fmt.Sprintf("%d-%s.bin", num, hex.EncodeToString(sum[:6])))
}

// Read returns the backup, or "" when the account has none.
func (s *BackupStore) Read(_ context.Context, num int, email string) (domain.CredentialBlob, error) {
	data, err := os.ReadFile(s.path(num, email))
	if errors.Is(err, fs.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	plain, err := s.unprotect(data)
	if err != nil {
		return "", fmt.Errorf("decrypt backup for account %d: %w", num, err)
	}
	return domain.CredentialBlob(plain), nil
}

// ReadFresh is Read: nothing is cached in memory.
func (s *BackupStore) ReadFresh(ctx context.Context, num int, email string) (domain.CredentialBlob, error) {
	return s.Read(ctx, num, email)
}

// Write encrypts and atomically replaces the account's backup.
func (s *BackupStore) Write(_ context.Context, num int, email string, blob domain.CredentialBlob) error {
	enc, err := s.protect([]byte(blob))
	if err != nil {
		return fmt.Errorf("encrypt backup for account %d: %w", num, err)
	}
	return writeFileAtomic(s.path(num, email), enc)
}

// Delete removes the account's backup; a missing file is not an error.
func (s *BackupStore) Delete(_ context.Context, num int, email string) error {
	err := os.Remove(s.path(num, email))
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	return err
}
