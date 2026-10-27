package usecase

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

func snapshotTestService(liveEmail string) (*Service, *listTestBackupStore, domain.CredentialBlob) {
	liveBlob := credentialBlob("live-token", "live-refresh", time.Now().Add(time.Hour))
	backup := &listTestBackupStore{
		blobs:  map[int]domain.CredentialBlob{1: credentialBlob("old", "old-refresh", time.Now().Add(time.Hour))},
		writes: map[int]domain.CredentialBlob{},
	}
	var account *domain.OAuthAccount
	if liveEmail != "" {
		account = &domain.OAuthAccount{EmailAddress: liveEmail, OrganizationUUID: "org-1"}
	}
	svc := &Service{
		Live:   &switchTestLiveStore{read: liveBlob},
		Backup: backup,
		Config: switchTestConfigStore{cfg: &domain.ClaudeConfig{Raw: map[string]any{}, OAuthAccount: account}},
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{1},
			Accounts: map[int]*domain.Account{
				1: {Number: 1, Email: "active@example.com", OrganizationUUID: "org-1"},
			},
		}},
		Lock: switchTestLock{},
	}
	return svc, backup, liveBlob
}

func TestSnapshotActiveLiveCopiesMatchingLogin(t *testing.T) {
	svc, backup, live := snapshotTestService("Active@Example.com")
	if err := svc.SnapshotActiveLive(context.Background()); err != nil {
		t.Fatal(err)
	}
	if backup.writes[1] != live {
		t.Fatalf("backup = %q, want live", backup.writes[1])
	}
}

func TestSnapshotActiveLiveRefusesAnotherAccountsLogin(t *testing.T) {
	for _, email := range []string{"someone-else@example.com", ""} {
		svc, backup, _ := snapshotTestService(email)
		err := svc.SnapshotActiveLive(context.Background())
		if !errors.Is(err, ErrLiveIdentityMismatch) {
			t.Fatalf("live %q: err = %v, want ErrLiveIdentityMismatch", email, err)
		}
		if len(backup.writes) != 0 {
			t.Fatalf("live %q: backup written: %v", email, backup.writes)
		}
	}
}
