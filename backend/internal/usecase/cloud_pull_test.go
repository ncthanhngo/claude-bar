package usecase

import (
	"context"
	"errors"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/cloudsync"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// pullTestBackupStore records writes and can inject per-account write errors.
type pullTestBackupStore struct {
	mu         sync.Mutex
	blobs      map[int]domain.CredentialBlob
	writeErrs  map[int]error // if set for account num, Write returns that error
	writeCalls []int
}

func (s *pullTestBackupStore) Read(_ context.Context, num int, _ string) (domain.CredentialBlob, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.blobs[num], nil
}
func (s *pullTestBackupStore) Write(_ context.Context, num int, _ string, b domain.CredentialBlob) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.writeCalls = append(s.writeCalls, num)
	if err, ok := s.writeErrs[num]; ok {
		return err
	}
	if s.blobs == nil {
		s.blobs = map[int]domain.CredentialBlob{}
	}
	s.blobs[num] = b
	return nil
}
func (s *pullTestBackupStore) Delete(context.Context, int, string) error { return nil }

// get returns the stored blob for num under the lock (safe for concurrent use).
func (s *pullTestBackupStore) get(num int) domain.CredentialBlob {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.blobs[num]
}

// pullTestRegistry records Save calls and can inject a save error.
type pullTestRegistry struct {
	mu        sync.Mutex
	reg       *domain.Registry
	saveCalls int
	saveErr   error
}

func (r *pullTestRegistry) Load(context.Context) (*domain.Registry, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.reg, nil
}
func (r *pullTestRegistry) Save(_ context.Context, reg *domain.Registry) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.saveCalls++
	if r.saveErr != nil {
		return r.saveErr
	}
	r.reg = reg
	return nil
}

// pullTestRefresher counts calls atomically.
type pullTestRefresher struct {
	calls int64
	err   error
}

func (r *pullTestRefresher) Refresh(context.Context, string) (*domain.OAuthPayload, error) {
	atomic.AddInt64(&r.calls, 1)
	if r.err != nil {
		return nil, r.err
	}
	return &domain.OAuthPayload{
		AccessToken:  "fresh",
		RefreshToken: "fresh-rt",
		ExpiresAt:    time.Now().Add(time.Hour).UnixMilli(),
	}, nil
}

// pullTestMCPSecretStore is a no-op implementation used in tests that don't
// exercise MCP connector restore logic.
type pullTestMCPSecretStore struct{}

func (pullTestMCPSecretStore) Read(_ context.Context, _ int, _ domain.MCPService) (string, error) {
	return "", nil
}
func (pullTestMCPSecretStore) Write(_ context.Context, _ int, _ domain.MCPService, _ string) error {
	return nil
}
func (pullTestMCPSecretStore) Delete(_ context.Context, _ int, _ domain.MCPService) error {
	return nil
}
func (pullTestMCPSecretStore) DeleteAll(_ context.Context, _ int) error { return nil }
func (pullTestMCPSecretStore) IsMigratedToShared(_ context.Context) (bool, error)  { return false, nil }
func (pullTestMCPSecretStore) MarkMigratedToShared(_ context.Context, _ time.Time) error { return nil }

// writeBundleFile writes an encrypted bundle to a temp file and patches
// cloudsync.BundlePathForTest so BundlePath() returns that path for the test.
func writeBundleFile(t *testing.T, bundle *cloudsync.CloudBundle, passphrase string) func() {
	t.Helper()
	enc, err := cloudsync.Encrypt(bundle, passphrase)
	if err != nil {
		t.Fatalf("encrypt bundle: %v", err)
	}
	f, err := os.CreateTemp(t.TempDir(), "bundle-*.enc")
	if err != nil {
		t.Fatalf("create temp bundle: %v", err)
	}
	if _, err := f.Write(enc); err != nil {
		t.Fatalf("write temp bundle: %v", err)
	}
	f.Close()
	cloudsync.BundlePathForTest = f.Name()
	t.Cleanup(func() { cloudsync.BundlePathForTest = "" })
	return func() { os.Remove(f.Name()) }
}

func makeBundle(accounts []cloudsync.BundleAccount) *cloudsync.CloudBundle {
	return &cloudsync.CloudBundle{
		Version:  2,
		PushedAt: time.Now().UTC(),
		Accounts: accounts,
	}
}

// TestCloudPull_OptionA_LocalFresher_WritesLocalBlob — local is newer than bundle
// → local blob must be preserved (not overwritten).
//
// Bundle no longer carries CredentialBlob (metadata-only sync), so the
// "merge" half of the original Option-A contract is moot. What remains
// worth asserting is the negative: CloudPull never overwrites the local
// backup blob. The other Option-A variants (BundleFresher / LocalNotExist
// / SameExpiresAt) and the keychain-write partial-failure test were
// removed when credential sync was dropped — see commit 10c4034.
func TestCloudPull_OptionA_LocalFresher_WritesLocalBlob(t *testing.T) {
	bundleBlob := credentialBlob("bundle-token", "bundle-rt", time.Now().Add(time.Hour))
	localBlob := credentialBlob("local-token", "local-rt", time.Now().Add(2*time.Hour))
	passphrase := "test-pass"

	cleanup := writeBundleFile(t, makeBundle([]cloudsync.BundleAccount{
		{Number: 1, Email: "a@example.com", CredentialBlob: string(bundleBlob)},
	}), passphrase)
	defer cleanup()

	bak := &pullTestBackupStore{blobs: map[int]domain.CredentialBlob{1: localBlob}}
	reg := &pullTestRegistry{reg: &domain.Registry{
		ActiveAccountNumber: 0,
		Accounts:            map[int]*domain.Account{},
		Sequence:            []int{},
	}}

	svc := &Service{
		Backup:     bak,
		Registry:   reg,
		Lock:       &pushTestLock{},
		Refresh:    &pullTestRefresher{err: errors.New("refresh disabled")},
		MCPSecrets: pullTestMCPSecretStore{},
	}

	if err := svc.CloudPull(context.Background(), passphrase); err != nil {
		t.Fatalf("CloudPull returned error: %v", err)
	}
	if got := bak.get(1); string(got) != string(localBlob) {
		t.Fatalf("expected local blob to be preserved, got %q", got)
	}
}

// TestCloudPull_PreservesActiveLocalIdentityWhenBundleNumberCollides — when a
// bundle account number collides with an unrelated local active account,
// CloudPull must keep the local identity in its slot and assign the bundle
// account to a fresh slot.
func TestCloudPull_PreservesActiveLocalIdentityWhenBundleNumberCollides(t *testing.T) {
	passphrase := "test-pass"

	cleanup := writeBundleFile(t, makeBundle([]cloudsync.BundleAccount{
		{
			Number:           4,
			Email:            "soi@example.com",
			OrganizationUUID: "soi-org",
		},
	}), passphrase)
	defer cleanup()

	reg := &pullTestRegistry{reg: &domain.Registry{
		ActiveAccountNumber: 4,
		Accounts: map[int]*domain.Account{
			4: {Number: 4, Email: "dev3@example.com", OrganizationUUID: "dev3-org"},
		},
		Sequence: []int{4},
	}}
	bak := &pullTestBackupStore{blobs: map[int]domain.CredentialBlob{}}
	svc := &Service{
		Backup:     bak,
		Registry:   reg,
		Lock:       &pushTestLock{},
		Refresh:    &pullTestRefresher{err: errors.New("refresh disabled")},
		MCPSecrets: pullTestMCPSecretStore{},
	}

	if err := svc.CloudPull(context.Background(), passphrase); err != nil {
		t.Fatalf("CloudPull returned error: %v", err)
	}
	if got := reg.reg.Accounts[4].Email; got != "dev3@example.com" {
		t.Fatalf("active local slot email = %q, want dev3@example.com", got)
	}
	if reg.reg.ActiveAccountNumber != 4 {
		t.Fatalf("active account number = %d, want 4", reg.reg.ActiveAccountNumber)
	}
	pulledNum := reg.reg.FindByIdentity("soi@example.com", "soi-org")
	if pulledNum == 0 || pulledNum == 4 {
		t.Fatalf("pulled account number = %d, want a new local slot", pulledNum)
	}
}

// Pull runs in a short-lived CLI process. It must not consume a restored
// rotating refresh token in a goroutine that can exit before the replacement is
// written back to Keychain; switch/verify will refresh synchronously later.
func TestCloudPullDoesNotRefreshRestoredCredentialsInBackground(t *testing.T) {
	blob := credentialBlob("t", "r", time.Now().Add(time.Hour))
	passphrase := "test-pass"

	cleanup := writeBundleFile(t, makeBundle([]cloudsync.BundleAccount{
		{Number: 1, Email: "a@example.com", CredentialBlob: string(blob)},
	}), passphrase)
	defer cleanup()

	bak := &pullTestBackupStore{blobs: map[int]domain.CredentialBlob{}}
	refresher := &pullTestRefresher{}
	reg := &pullTestRegistry{reg: &domain.Registry{
		ActiveAccountNumber: 0, // no active account so RefreshAllTokens has work to do
		Accounts:            map[int]*domain.Account{},
		Sequence:            []int{},
	}}

	svc := &Service{
		Backup:     bak,
		Registry:   reg,
		Lock:       &pushTestLock{},
		Refresh:    refresher,
		MCPSecrets: pullTestMCPSecretStore{},
	}
	if err := svc.CloudPull(context.Background(), passphrase); err != nil {
		t.Fatalf("CloudPull returned error: %v", err)
	}
	time.Sleep(100 * time.Millisecond)
	if got := atomic.LoadInt64(&refresher.calls); got != 0 {
		t.Fatalf("refresh calls after pull = %d, want 0", got)
	}
}
