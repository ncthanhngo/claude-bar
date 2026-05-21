package keychain

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// backupServiceFormat keeps each inactive account in its own Keychain entry,
// scoped by widget so it never collides with Claude Code's live entry.
const backupServiceFormat = "csw-backup:%d:%s"

// BackupCredentialStore holds credentials for inactive accounts.
// An in-memory cache avoids repeated Keychain reads (and permission dialogs)
// within a single daemon lifetime. The cache is invalidated on every Write so
// the next Read reflects the freshly-written item (which carries a permissive ACL).
type BackupCredentialStore struct {
	user  string
	mu    sync.RWMutex
	cache map[string]domain.CredentialBlob
}

// NewBackupCredentialStore binds to the current $USER.
func NewBackupCredentialStore() *BackupCredentialStore {
	user := os.Getenv("USER")
	if user == "" {
		user = "user"
	}
	return &BackupCredentialStore{
		user:  user,
		cache: make(map[string]domain.CredentialBlob),
	}
}

func (s *BackupCredentialStore) key(accountNum int, email string) string {
	return fmt.Sprintf(backupServiceFormat, accountNum, email)
}

func (s *BackupCredentialStore) kc(accountNum int, email string) *Keychain {
	return New(s.key(accountNum, email), s.user)
}

// Read returns the backed-up credential for an inactive account.
// Results are cached in memory so the Keychain is only accessed once per
// daemon lifetime per account — subsequent calls return the cached value
// without triggering a macOS permission dialog.
func (s *BackupCredentialStore) Read(ctx context.Context, accountNum int, email string) (domain.CredentialBlob, error) {
	k := s.key(accountNum, email)

	s.mu.RLock()
	if blob, ok := s.cache[k]; ok {
		s.mu.RUnlock()
		return blob, nil
	}
	s.mu.RUnlock()

	kc := s.kc(accountNum, email)
	out, err := kc.Read(ctx)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return "", nil
		}
		return "", err
	}
	blob := domain.CredentialBlob(out)

	// One-time ACL migration: delete the old restrictive-ACL item and recreate
	// without an ACL so future reads from any process never prompt again.
	// The delete does not access the secret, so no second dialog appears.
	_ = kc.Migrate(ctx, out)

	s.mu.Lock()
	s.cache[k] = blob
	s.mu.Unlock()

	return blob, nil
}

// Write saves a backup credential and updates the in-memory cache so the
// next Read reflects the new value without going back to Keychain.
func (s *BackupCredentialStore) Write(ctx context.Context, accountNum int, email string, blob domain.CredentialBlob) error {
	if err := s.kc(accountNum, email).Write(ctx, string(blob)); err != nil {
		return err
	}
	k := s.key(accountNum, email)
	s.mu.Lock()
	s.cache[k] = blob
	s.mu.Unlock()
	return nil
}

// Delete removes a backup credential and evicts the cache entry.
func (s *BackupCredentialStore) Delete(ctx context.Context, accountNum int, email string) error {
	k := s.key(accountNum, email)
	s.mu.Lock()
	delete(s.cache, k)
	s.mu.Unlock()
	return s.kc(accountNum, email).Delete(ctx)
}
