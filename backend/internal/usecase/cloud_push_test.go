package usecase

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/cloudsync"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// isolateCloudIO redirects bundle + sync-state writes to temp paths so push
// tests do not pollute the developer's real iCloud Drive or Application
// Support directories. Cleanup restores the overrides.
func isolateCloudIO(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	cloudsync.BundlePathForTest = filepath.Join(dir, "bundle.enc")
	cloudsync.SyncStatePathForTest = filepath.Join(dir, "sync-state.json")
	t.Cleanup(func() {
		cloudsync.BundlePathForTest = ""
		cloudsync.SyncStatePathForTest = ""
	})
}

// pushTestLiveStore returns a configurable blob or error.
type pushTestLiveStore struct {
	blob domain.CredentialBlob
	err  error
}

func (s *pushTestLiveStore) Read(context.Context) (domain.CredentialBlob, error) {
	return s.blob, s.err
}
func (s *pushTestLiveStore) Write(context.Context, domain.CredentialBlob) error { return nil }

// pushTestBackupStore delegates to listTestBackupStore but records Read calls.
type pushTestBackupStore struct {
	blobs     map[int]domain.CredentialBlob
	readCalls []int
	mu        sync.Mutex
}

func (s *pushTestBackupStore) Read(_ context.Context, num int, _ string) (domain.CredentialBlob, error) {
	s.mu.Lock()
	s.readCalls = append(s.readCalls, num)
	s.mu.Unlock()
	return s.blobs[num], nil
}
func (s *pushTestBackupStore) Write(_ context.Context, num int, _ string, b domain.CredentialBlob) error {
	s.mu.Lock()
	s.blobs[num] = b
	s.mu.Unlock()
	return nil
}
func (s *pushTestBackupStore) Delete(context.Context, int, string) error { return nil }

// pushTestLock records acquisition order for Option B verification.
type pushTestLock struct {
	mu       sync.Mutex
	acquired []string
	locked   bool
}

func (l *pushTestLock) Acquire(context.Context) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.acquired = append(l.acquired, "acquire")
	l.locked = true
	return nil
}
func (l *pushTestLock) Release() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.locked = false
	return nil
}

// pushTestRefresher records calls and their order relative to a shared sequence.
type pushTestRefresher struct {
	mu       sync.Mutex
	calls    int
	sequence *[]string // shared pointer so lock and refresher write to same slice
	err      error
}

func (r *pushTestRefresher) Refresh(context.Context, string) (*domain.OAuthPayload, error) {
	r.mu.Lock()
	r.calls++
	if r.sequence != nil {
		*r.sequence = append(*r.sequence, "refresh")
	}
	r.mu.Unlock()
	if r.err != nil {
		return nil, r.err
	}
	return &domain.OAuthPayload{
		AccessToken:  "fresh",
		RefreshToken: "fresh-rt",
		ExpiresAt:    time.Now().Add(time.Hour).UnixMilli(),
	}, nil
}

// pushTestRegistry is a simple in-memory registry.
type pushTestRegistry struct {
	reg *domain.Registry
}

func (r *pushTestRegistry) Load(context.Context) (*domain.Registry, error) { return r.reg, nil }
func (r *pushTestRegistry) Save(_ context.Context, reg *domain.Registry) error {
	r.reg = reg
	return nil
}

func makeCloudPushService(live *pushTestLiveStore, bak *pushTestBackupStore, lock *pushTestLock, refresher *pushTestRefresher, reg *domain.Registry) *Service {
	return &Service{
		Live:     live,
		Backup:   bak,
		Lock:     lock,
		Refresh:  refresher,
		Registry: &pushTestRegistry{reg: reg},
	}
}

// TestCloudPushFailsWhenInactiveCredentialRefreshFails verifies that a HARD
// refresh failure (network / 5xx) aborts the push — re-trying later is the
// right move for a transient outage, and a healthy-looking bundle pushed
// during a flaky network would mislead other devices.
func TestCloudPushFailsWhenInactiveCredentialRefreshFails(t *testing.T) {
	reg := &domain.Registry{
		ActiveAccountNumber: 1,
		Sequence:            []int{1, 2},
		Accounts: map[int]*domain.Account{
			1: {Number: 1, Email: "active@example.com"},
			2: {Number: 2, Email: "inactive@example.com"},
		},
	}
	lock := &pushTestLock{}
	svc := makeCloudPushService(
		&pushTestLiveStore{blob: credentialBlob("live-token", "live-rt", time.Now().Add(time.Hour))},
		&pushTestBackupStore{blobs: map[int]domain.CredentialBlob{
			2: credentialBlob("stale-token", "revoked-rt", time.Now().Add(-time.Hour)),
		}},
		lock,
		&pushTestRefresher{err: errors.New("dial tcp: i/o timeout")},
		reg,
	)

	err := svc.CloudPush(context.Background(), "test-pass")
	if err == nil {
		t.Fatal("CloudPush returned nil for hard refresh failure")
	}
	if !strings.Contains(err.Error(), "refresh inactive credentials before push") {
		t.Fatalf("CloudPush error = %q, want pre-push refresh context", err)
	}
	if lock.locked || len(lock.acquired) != 0 {
		t.Fatalf("CloudPush acquired lock after failed pre-push refresh: %+v", lock)
	}
}

// TestCloudPushSucceedsWhenInactiveNeedsRelogin verifies that a per-account
// permanent failure (400 invalid_grant — revoked refresh token) does NOT
// block the push. Withholding the whole bundle on one bad token was the
// real bug: the other accounts and shared MCP connectors still need to
// sync, and the broken account is fixed independently by re-login.
func TestCloudPushSucceedsWhenInactiveNeedsRelogin(t *testing.T) {
	isolateCloudIO(t)
	reg := &domain.Registry{
		ActiveAccountNumber: 1,
		Sequence:            []int{1, 2},
		Accounts: map[int]*domain.Account{
			1: {Number: 1, Email: "active@example.com"},
			2: {Number: 2, Email: "inactive@example.com"},
		},
	}
	lock := &pushTestLock{}
	svc := makeCloudPushService(
		&pushTestLiveStore{blob: credentialBlob("live-token", "live-rt", time.Now().Add(time.Hour))},
		&pushTestBackupStore{blobs: map[int]domain.CredentialBlob{
			2: credentialBlob("stale-token", "revoked-rt", time.Now().Add(time.Hour)),
		}},
		lock,
		&pushTestRefresher{err: errors.New(`oauth refresh 400: {"error":"invalid_grant"}`)},
		reg,
	)

	if err := svc.CloudPush(context.Background(), "test-pass"); err != nil {
		t.Fatalf("CloudPush returned %v, want nil (needs-relogin must not block push)", err)
	}
	if !lock.locked && len(lock.acquired) == 0 {
		t.Fatal("CloudPush did not acquire push lock — expected push to proceed past the soft refresh failure")
	}
}

// TestCloudPush_OptionB_RefreshCalledBeforeLock verifies that RefreshAllTokens
// is invoked before Lock.Acquire so network calls never run under the file lock.
func TestCloudPush_OptionB_RefreshCalledBeforeLock(t *testing.T) {
	isolateCloudIO(t)
	var seq []string

	instrLock := &seqRecordingLock{seq: &seq}
	inactiveBlob := credentialBlob("inactive-token", "inactive-rt", time.Now().Add(time.Hour))
	refresher := &pushTestRefresher{sequence: &seq}

	reg := &domain.Registry{
		ActiveAccountNumber: 1,
		Sequence:            []int{1, 2},
		Accounts: map[int]*domain.Account{
			1: {Number: 1, Email: "a1@example.com"},
			2: {Number: 2, Email: "a2@example.com"},
		},
	}
	bak := &pushTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			2: inactiveBlob,
		},
	}
	live := &pushTestLiveStore{blob: credentialBlob("live-token", "live-rt", time.Now().Add(time.Hour))}

	svc := &Service{
		Live:     live,
		Backup:   bak,
		Lock:     instrLock,
		Refresh:  refresher,
		Registry: &pushTestRegistry{reg: reg},
	}

	// CloudPush writes a real file — skip file I/O by checking the sequence up
	// to the point we care about (RefreshAllTokens before Lock.Acquire).
	// We drive it through a passphrase that will work but the actual push may
	// fail because there is no real iCloud path in tests — that's acceptable.
	_ = svc.CloudPush(context.Background(), "test-pass")

	// Verify refresh precedes acquire in the sequence.
	refreshIdx, acquireIdx := -1, -1
	for i, ev := range seq {
		switch ev {
		case "refresh":
			if refreshIdx < 0 {
				refreshIdx = i
			}
		case "acquire":
			if acquireIdx < 0 {
				acquireIdx = i
			}
		}
	}
	if refreshIdx < 0 {
		t.Fatal("RefreshAllTokens was never called")
	}
	if acquireIdx < 0 {
		t.Fatal("Lock.Acquire was never called")
	}
	if refreshIdx > acquireIdx {
		t.Fatalf("RefreshAllTokens called after Lock.Acquire (seq=%v)", seq)
	}
}

// seqRecordingLock records "acquire" into a shared sequence slice.
type seqRecordingLock struct {
	seq *[]string
}

func (l *seqRecordingLock) Acquire(context.Context) error {
	*l.seq = append(*l.seq, "acquire")
	return nil
}
func (l *seqRecordingLock) Release() error { return nil }

// TestCloudPush_R2_ActiveLiveFailFallsBackToBackup verifies that when the live
// keychain read fails, the active account's backup is used instead.
func TestCloudPush_R2_ActiveLiveFailFallsBackToBackup(t *testing.T) {
	isolateCloudIO(t)
	backupBlob := credentialBlob("backup-token", "backup-rt", time.Now().Add(time.Hour))
	reg := &domain.Registry{
		ActiveAccountNumber: 1,
		Sequence:            []int{1},
		Accounts:            map[int]*domain.Account{1: {Number: 1, Email: "a@example.com"}},
	}
	svc := &Service{
		Live:     &pushTestLiveStore{err: errors.New("keychain locked")},
		Backup:   &pushTestBackupStore{blobs: map[int]domain.CredentialBlob{1: backupBlob}},
		Lock:     &pushTestLock{},
		Refresh:  &pushTestRefresher{},
		Registry: &pushTestRegistry{reg: reg},
	}

	// The push will fail at the encrypt/write stage because there's no real iCloud
	// path, but it must NOT return the "cannot push" sentinel — the fallback worked.
	err := svc.CloudPush(context.Background(), "pass")
	if err != nil && strings.Contains(err.Error(), "cannot push") {
		t.Fatalf("expected fallback to succeed, got: %v", err)
	}
}

// TestCloudPush_R2_ActiveLiveFailNoBackup_ReturnsError verifies that when both
// the live read and the backup are empty, CloudPush returns an explicit error.
func TestCloudPush_R2_ActiveLiveFailNoBackup_ReturnsError(t *testing.T) {
	reg := &domain.Registry{
		ActiveAccountNumber: 1,
		Sequence:            []int{1},
		Accounts:            map[int]*domain.Account{1: {Number: 1, Email: "a@example.com"}},
	}
	svc := &Service{
		Live:     &pushTestLiveStore{err: errors.New("keychain locked")},
		Backup:   &pushTestBackupStore{blobs: map[int]domain.CredentialBlob{}},
		Lock:     &pushTestLock{},
		Refresh:  &pushTestRefresher{},
		Registry: &pushTestRegistry{reg: reg},
	}

	err := svc.CloudPush(context.Background(), "pass")
	if err == nil {
		t.Fatal("expected error when live and backup both empty, got nil")
	}
	if !strings.Contains(err.Error(), "cannot push") {
		t.Fatalf("error does not mention 'cannot push': %v", err)
	}
}
