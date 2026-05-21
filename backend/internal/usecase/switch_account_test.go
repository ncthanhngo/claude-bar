package usecase

import (
	"context"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

type switchTestLiveStore struct {
	written domain.CredentialBlob
}

func (s *switchTestLiveStore) Read(context.Context) (domain.CredentialBlob, error) {
	t := domain.CredentialBlob("")
	return t, nil
}

func (s *switchTestLiveStore) Write(_ context.Context, blob domain.CredentialBlob) error {
	s.written = blob
	return nil
}

type switchTestLock struct{}

func (switchTestLock) Acquire(context.Context) error { return nil }
func (switchTestLock) Release() error                { return nil }

func TestSwitchAccountAlreadyActiveRepairsLiveCredential(t *testing.T) {
	live := &switchTestLiveStore{}
	backup := &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			1: credentialBlob("active-token", "refresh-token", time.Now().Add(time.Hour)),
		},
		writes: map[int]domain.CredentialBlob{},
	}

	svc := &Service{
		Live:   live,
		Backup: backup,
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{1},
			Accounts: map[int]*domain.Account{
				1: {Number: 1, Email: "active@example.com"},
			},
		}},
		Refresh: &listTestTokenRefresher{},
		Lock:    switchTestLock{},
	}

	if err := svc.SwitchAccount(context.Background(), 1); err != nil {
		t.Fatalf("SwitchAccount(active) returned error: %v", err)
	}
	if live.written == "" {
		t.Fatal("active switch did not rewrite live credential")
	}
}

func TestRepairLiveCredentialUsesActiveBackup(t *testing.T) {
	live := &switchTestLiveStore{}
	backup := &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			1: credentialBlob("active-token", "refresh-token", time.Now().Add(time.Hour)),
		},
		writes: map[int]domain.CredentialBlob{},
	}

	svc := &Service{
		Live:   live,
		Backup: backup,
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{1},
			Accounts: map[int]*domain.Account{
				1: {Number: 1, Email: "active@example.com"},
			},
		}},
		Refresh: &listTestTokenRefresher{},
		Lock:    switchTestLock{},
	}

	if err := svc.RepairLiveCredential(context.Background()); err != nil {
		t.Fatalf("RepairLiveCredential returned error: %v", err)
	}
	if live.written == "" {
		t.Fatal("repair did not rewrite live credential")
	}
}
