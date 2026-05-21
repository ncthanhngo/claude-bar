package usecase

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

type switchTestLiveStore struct {
	read    domain.CredentialBlob
	written domain.CredentialBlob
}

func (s *switchTestLiveStore) Read(context.Context) (domain.CredentialBlob, error) {
	return s.read, nil
}

func (s *switchTestLiveStore) Write(_ context.Context, blob domain.CredentialBlob) error {
	s.written = blob
	return nil
}

type switchTestLock struct{}

func (switchTestLock) Acquire(context.Context) error { return nil }
func (switchTestLock) Release() error                { return nil }

type switchTestRecordingRegistryStore struct {
	reg   *domain.Registry
	saved *domain.Registry
}

func (s *switchTestRecordingRegistryStore) Load(context.Context) (*domain.Registry, error) {
	return s.reg, nil
}
func (s *switchTestRecordingRegistryStore) Save(_ context.Context, reg *domain.Registry) error {
	s.saved = reg
	return nil
}

type switchTestConfigStore struct {
	cfg *domain.ClaudeConfig
}

func (s switchTestConfigStore) Read(context.Context) (*domain.ClaudeConfig, error) {
	return s.cfg, nil
}

func (s switchTestConfigStore) Write(context.Context, *domain.ClaudeConfig) error { return nil }
func (s switchTestConfigStore) Exists() bool                                      { return true }

type switchTestRecordingConfigStore struct {
	cfg     *domain.ClaudeConfig
	written *domain.ClaudeConfig
}

func (s *switchTestRecordingConfigStore) Read(context.Context) (*domain.ClaudeConfig, error) {
	return s.cfg, nil
}
func (s *switchTestRecordingConfigStore) Write(_ context.Context, cfg *domain.ClaudeConfig) error {
	s.written = cfg
	return nil
}
func (s *switchTestRecordingConfigStore) Exists() bool { return true }

func TestSwitchAccountAlreadyActiveRepairsLiveCredentialAndClaudeConfig(t *testing.T) {
	live := &switchTestLiveStore{}
	backup := &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			1: credentialBlob("active-token", "refresh-token", time.Now().Add(time.Hour)),
		},
		writes: map[int]domain.CredentialBlob{},
	}
	config := &switchTestRecordingConfigStore{cfg: &domain.ClaudeConfig{
		Raw: map[string]any{},
		OAuthAccount: &domain.OAuthAccount{
			EmailAddress:     "stale@example.com",
			OrganizationName: "Stale Org",
			OrganizationUUID: "stale-org",
		},
	}}

	svc := &Service{
		Live:   live,
		Backup: backup,
		Config: config,
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{1},
			Accounts: map[int]*domain.Account{
				1: {
					Number:           1,
					Email:            "active@example.com",
					OrganizationName: "Active Org",
					OrganizationUUID: "active-org",
				},
			},
		}},
		Refresh: refreshedSwitchToken(),
		Lock:    switchTestLock{},
	}

	if err := svc.SwitchAccount(context.Background(), 1); err != nil {
		t.Fatalf("SwitchAccount(active) returned error: %v", err)
	}
	if live.written == "" {
		t.Fatal("active switch did not rewrite live credential")
	}
	if config.written == nil || config.written.OAuthAccount == nil {
		t.Fatal("active switch did not rewrite claude config")
	}
	if got := config.written.OAuthAccount.EmailAddress; got != "active@example.com" {
		t.Fatalf("claude config email = %q, want active@example.com", got)
	}
	if got := config.written.OAuthAccount.OrganizationUUID; got != "active-org" {
		t.Fatalf("claude config org = %q, want active-org", got)
	}
}

func TestSwitchAccountAdoptsConfigActiveAccountWhenRegistryDrifts(t *testing.T) {
	liveBlob := credentialBlob("live-token", "live-refresh", time.Now().Add(time.Hour))
	live := &switchTestLiveStore{read: liveBlob}
	backup := &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			1: credentialBlob("registry-token", "registry-refresh", time.Now().Add(time.Hour)),
			2: credentialBlob("stale-token", "revoked-refresh", time.Now().Add(-time.Hour)),
		},
		writes: map[int]domain.CredentialBlob{},
	}
	registry := &switchTestRecordingRegistryStore{reg: &domain.Registry{
		ActiveAccountNumber: 1,
		Sequence:            []int{1, 2},
		Accounts: map[int]*domain.Account{
			1: {Number: 1, Email: "registry@example.com", OrganizationUUID: "registry-org"},
			2: {Number: 2, Email: "config@example.com", OrganizationUUID: "config-org"},
		},
	}}
	svc := &Service{
		Live:   live,
		Backup: backup,
		Config: switchTestConfigStore{cfg: &domain.ClaudeConfig{
			OAuthAccount: &domain.OAuthAccount{
				EmailAddress:     "config@example.com",
				OrganizationUUID: "config-org",
			},
		}},
		Registry: registry,
		Refresh:  &listTestTokenRefresher{err: errors.New("invalid_grant")},
		Lock:     switchTestLock{},
	}

	if err := svc.SwitchAccount(context.Background(), 2); err != nil {
		t.Fatalf("SwitchAccount(config active) returned error: %v", err)
	}
	if registry.saved == nil || registry.saved.ActiveAccountNumber != 2 {
		t.Fatalf("saved active account = %+v, want config account 2", registry.saved)
	}
	if backup.writes[2] != liveBlob {
		t.Fatalf("config-active backup = %q, want live snapshot", backup.writes[2])
	}
	if live.written != "" {
		t.Fatalf("config-active switch rewrote live credential: %q", live.written)
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
		Refresh: refreshedSwitchToken(),
		Lock:    switchTestLock{},
	}

	if err := svc.RepairLiveCredential(context.Background()); err != nil {
		t.Fatalf("RepairLiveCredential returned error: %v", err)
	}
	if live.written == "" {
		t.Fatal("repair did not rewrite live credential")
	}
}

func TestRepairLiveCredentialFallsBackToStoredBackupWhenRefreshFails(t *testing.T) {
	live := &switchTestLiveStore{}
	stored := credentialBlob("stored-token", "revoked-refresh", time.Now().Add(-time.Hour))
	svc := &Service{
		Live: live,
		Backup: &listTestBackupStore{
			blobs: map[int]domain.CredentialBlob{
				1: stored,
			},
			writes: map[int]domain.CredentialBlob{},
		},
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{1},
			Accounts: map[int]*domain.Account{
				1: {Number: 1, Email: "active@example.com"},
			},
		}},
		Refresh: &listTestTokenRefresher{err: errors.New("oauth refresh 400")},
		Lock:    switchTestLock{},
	}

	if err := svc.RepairLiveCredential(context.Background()); err != nil {
		t.Fatalf("RepairLiveCredential returned error: %v", err)
	}
	if live.written != stored {
		t.Fatalf("repair wrote %q, want stored backup", live.written)
	}
}

func TestSwitchAccountFailsWhenTargetBackupRefreshFails(t *testing.T) {
	activeLive := credentialBlob("active-live-token", "active-live-refresh", time.Now().Add(time.Hour))
	live := &switchTestLiveStore{read: activeLive}
	svc := &Service{
		Live: live,
		Backup: &listTestBackupStore{
			blobs: map[int]domain.CredentialBlob{
				1: activeLive,
				2: credentialBlob("stale-token", "revoked-refresh", time.Now().Add(-time.Hour)),
			},
			writes: map[int]domain.CredentialBlob{},
		},
		Config: switchTestConfigStore{cfg: &domain.ClaudeConfig{Raw: map[string]any{}}},
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{1, 2},
			Accounts: map[int]*domain.Account{
				1: {Number: 1, Email: "active@example.com"},
				2: {Number: 2, Email: "target@example.com"},
			},
		}},
		Refresh: &listTestTokenRefresher{err: errors.New("oauth refresh 400 invalid_grant")},
		Lock:    switchTestLock{},
	}

	err := svc.SwitchAccount(context.Background(), 2)
	if err == nil {
		t.Fatal("SwitchAccount returned nil for stale target backup")
	}
	if want := "account 2 credentials need login again"; !strings.Contains(err.Error(), want) {
		t.Fatalf("SwitchAccount error = %q, want it to contain %q", err, want)
	}
	if live.written != "" {
		t.Fatalf("stale target credential was written live: %q", live.written)
	}
}

func TestSwitchAccountSnapshotsLiveCredentialBeforeOverwritingIt(t *testing.T) {
	activeLive := credentialBlob("active-live-token", "rotated-live-refresh", time.Now().Add(time.Hour))
	live := &switchTestLiveStore{read: activeLive}
	backup := &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			1: credentialBlob("old-active-token", "old-active-refresh", time.Now().Add(time.Hour)),
			2: credentialBlob("target-token", "target-refresh", time.Now().Add(time.Hour)),
		},
		writes: map[int]domain.CredentialBlob{},
	}
	svc := &Service{
		Live:   live,
		Backup: backup,
		Config: switchTestConfigStore{cfg: &domain.ClaudeConfig{
			Raw: map[string]any{},
		}},
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{1, 2},
			Accounts: map[int]*domain.Account{
				1: {Number: 1, Email: "active@example.com"},
				2: {Number: 2, Email: "target@example.com"},
			},
		}},
		Refresh: refreshedSwitchToken(),
		Lock:    switchTestLock{},
	}

	if err := svc.SwitchAccount(context.Background(), 2); err != nil {
		t.Fatalf("SwitchAccount returned error: %v", err)
	}
	if backup.writes[1] != activeLive {
		t.Fatalf("active backup = %q, want live snapshot", backup.writes[1])
	}
	if live.written == "" || live.written == activeLive {
		t.Fatalf("target live credential write = %q", live.written)
	}
}

func refreshedSwitchToken() *listTestTokenRefresher {
	return &listTestTokenRefresher{fresh: &domain.OAuthPayload{
		AccessToken:  "fresh-token",
		RefreshToken: "fresh-refresh",
		ExpiresAt:    time.Now().Add(time.Hour).UnixMilli(),
	}}
}

// failingConfigStore simulates a config write failure.
type failingConfigStore struct {
	cfg *domain.ClaudeConfig
}

func (s failingConfigStore) Read(context.Context) (*domain.ClaudeConfig, error) {
	if s.cfg != nil {
		return s.cfg, nil
	}
	return &domain.ClaudeConfig{Raw: map[string]any{}}, nil
}
func (failingConfigStore) Write(context.Context, *domain.ClaudeConfig) error {
	return errors.New("disk full")
}
func (failingConfigStore) Exists() bool { return true }

func TestSwitchAccountConfigWriteFailureRestoresPreviousActiveLive(t *testing.T) {
	// active account (1) has live cred; target (2) has valid backup.
	// When config write fails, live must be restored to the active's snapshot — not
	// left pointing at target identity while ~/.claude.json still names account 1.
	activeLive := credentialBlob("active-live", "active-refresh", time.Now().Add(time.Hour))
	live := &switchTestLiveStore{read: activeLive}
	backup := &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			1: activeLive,
			2: credentialBlob("target-token", "target-refresh", time.Now().Add(time.Hour)),
		},
		writes: map[int]domain.CredentialBlob{},
	}

	svc := &Service{
		Live:   live,
		Backup: backup,
		Config: failingConfigStore{},
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{1, 2},
			Accounts: map[int]*domain.Account{
				1: {Number: 1, Email: "active@example.com"},
				2: {Number: 2, Email: "target@example.com"},
			},
		}},
		Refresh: refreshedSwitchToken(),
		Lock:    switchTestLock{},
	}

	err := svc.SwitchAccount(context.Background(), 2)
	if err == nil {
		t.Fatal("expected error from config write failure")
	}

	// live.written tracks the last write. After rollback it should be the
	// active account's snapshotted credential (activeLive written in step 3).
	if live.written == "" {
		t.Fatal("rollback should have written to live")
	}
	// The snapshot written to backup[1] in step 3 equals activeLive; rollback
	// reads that and writes it back — live must match, not the target credential.
	if live.written != activeLive {
		t.Fatalf("live after rollback = %q, want active snapshot %q", live.written, activeLive)
	}
}

func TestSwitchAccountConfigWriteFailurePropagatesRollbackError(t *testing.T) {
	activeLive := credentialBlob("active-live", "active-refresh", time.Now().Add(time.Hour))

	live := &switchTestFailingWriteStore{read: activeLive}
	backup := &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			1: activeLive,
			2: credentialBlob("target-token", "target-refresh", time.Now().Add(time.Hour)),
		},
		writes: map[int]domain.CredentialBlob{},
	}

	svc := &Service{
		Live:   live,
		Backup: backup,
		Config: failingConfigStore{},
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{1, 2},
			Accounts: map[int]*domain.Account{
				1: {Number: 1, Email: "active@example.com"},
				2: {Number: 2, Email: "target@example.com"},
			},
		}},
		Refresh: refreshedSwitchToken(),
		Lock:    switchTestLock{},
	}

	err := svc.SwitchAccount(context.Background(), 2)
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "rollback write live") {
		t.Fatalf("error should mention rollback failure; got %q", err)
	}
}

// switchTestFailingWriteStore succeeds the first write (step 5: install target creds)
// then fails subsequent writes (rollback attempt in step 6 error path).
type switchTestFailingWriteStore struct {
	read   domain.CredentialBlob
	writes int
}

func (s *switchTestFailingWriteStore) Read(context.Context) (domain.CredentialBlob, error) {
	return s.read, nil
}
func (s *switchTestFailingWriteStore) Write(_ context.Context, _ domain.CredentialBlob) error {
	s.writes++
	if s.writes == 1 {
		return nil // step 5 succeeds; gets us to step 6 config write
	}
	return errors.New("keychain write denied")
}

// switchTestDeniedLiveStore simulates a Keychain ACL denial on Read (snapshot path)
// but allows Write (step 5: install target creds).
type switchTestDeniedLiveStore struct {
	written domain.CredentialBlob
}

func (s *switchTestDeniedLiveStore) Read(context.Context) (domain.CredentialBlob, error) {
	return "", errors.New("keychain ACL denied")
}
func (s *switchTestDeniedLiveStore) Write(_ context.Context, blob domain.CredentialBlob) error {
	s.written = blob
	return nil
}

// TestSwitchAccountProceedsWhenSnapshotLiveReadFails — if step 3 (snapshot) cannot
// read the live Keychain slot (ACL denied, transient error), the switch must still
// succeed. The target credential is installed; the rollback degrades to the
// pre-existing backup for the previously-active account.
func TestSwitchAccountProceedsWhenSnapshotLiveReadFails(t *testing.T) {
	live := &switchTestDeniedLiveStore{}
	targetBlob := credentialBlob("target-token", "target-refresh", time.Now().Add(time.Hour))
	backup := &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			1: credentialBlob("active-backup", "active-refresh", time.Now().Add(time.Hour)),
			2: targetBlob,
		},
		writes: map[int]domain.CredentialBlob{},
	}

	svc := &Service{
		Live:   live,
		Backup: backup,
		Config: switchTestConfigStore{cfg: &domain.ClaudeConfig{Raw: map[string]any{}}},
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{1, 2},
			Accounts: map[int]*domain.Account{
				1: {Number: 1, Email: "active@example.com"},
				2: {Number: 2, Email: "target@example.com"},
			},
		}},
		Refresh: refreshedSwitchToken(),
		Lock:    switchTestLock{},
	}

	if err := svc.SwitchAccount(context.Background(), 2); err != nil {
		t.Fatalf("SwitchAccount should succeed despite snapshot failure: %v", err)
	}
	if live.written == "" {
		t.Fatal("target credential was not installed to live slot")
	}
	// Snapshot failed so active account's backup should NOT have been updated.
	if _, snapshotted := backup.writes[1]; snapshotted {
		t.Fatal("snapshot should not have written to active backup when live read was denied")
	}
}

// TestSwitchAccountConfigWriteFailureWithDegradedSnapshot — when step 3 snapshot
// failed (live read denied), step 6 rollback must fall back to the pre-existing
// active backup rather than panicking or returning a rollback error.
func TestSwitchAccountConfigWriteFailureWithDegradedSnapshot(t *testing.T) {
	existingActiveBackup := credentialBlob("active-backup", "active-refresh", time.Now().Add(time.Hour))
	backup := &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			1: existingActiveBackup,
			2: credentialBlob("target-token", "target-refresh", time.Now().Add(time.Hour)),
		},
		writes: map[int]domain.CredentialBlob{},
	}

	// read="" causes snapshotLiveCredential to fail (empty blob error) → best-effort,
	// switch continues. Write still works so step 5 and rollback both track correctly.
	writableLive := &switchTestLiveStore{read: ""}

	svc := &Service{
		Live:   writableLive,
		Backup: backup,
		Config: failingConfigStore{},
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{1, 2},
			Accounts: map[int]*domain.Account{
				1: {Number: 1, Email: "active@example.com"},
				2: {Number: 2, Email: "target@example.com"},
			},
		}},
		Refresh: refreshedSwitchToken(),
		Lock:    switchTestLock{},
	}

	err := svc.SwitchAccount(context.Background(), 2)
	if err == nil {
		t.Fatal("expected config write error")
	}
	if strings.Contains(err.Error(), "rollback write live") {
		t.Fatalf("rollback should not produce secondary error when pre-existing backup exists: %v", err)
	}
	// Rollback must have written the pre-existing active backup to live.
	if writableLive.written != existingActiveBackup {
		t.Fatalf("degraded rollback wrote %q, want pre-existing active backup", writableLive.written)
	}
}
