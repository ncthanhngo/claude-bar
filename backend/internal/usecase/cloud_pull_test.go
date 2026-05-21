package usecase

import (
	"context"
	"errors"
	"os"
	"strings"
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

// pullTestRefresher counts calls atomically (used to verify R1 fires).
// Set err to make Refresh return an error (prevents background goroutine from
// overwriting blobs in option-A assertion tests).
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

// writeBundleFile writes an encrypted bundle to a temp file and returns the path,
// monkey-patching the BundlePath via env var understood by BundlePath().
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
	t.Setenv("CLAUDE_SWAP_BUNDLE_PATH", f.Name())
	return func() { os.Remove(f.Name()) }
}

func makeBundle(accounts []cloudsync.BundleAccount) *cloudsync.CloudBundle {
	return &cloudsync.CloudBundle{
		Version:  2,
		PushedAt: time.Now().UTC(),
		Accounts: accounts,
	}
}

// TestCloudPull_OptionA_BundleFresher_WritesBundleBlob — local is stale,
// bundle is newer → bundle blob must be written.
func TestCloudPull_OptionA_BundleFresher_WritesBundleBlob(t *testing.T) {
	bundleBlob := credentialBlob("bundle-token", "bundle-rt", time.Now().Add(2*time.Hour))
	localBlob := credentialBlob("local-token", "local-rt", time.Now().Add(time.Hour))
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

	// Failing refresher prevents the background R1 goroutine from overwriting the
	// blob we are about to assert on.
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
	if got := bak.get(1); string(got) != string(bundleBlob) {
		t.Fatalf("expected bundle blob to be written, got %q", got)
	}
}

// TestCloudPull_OptionA_LocalFresher_WritesLocalBlob — local is newer than bundle
// → local blob must be preserved (not overwritten).
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

// TestCloudPull_OptionA_LocalNotExist_WritesBundleBlob — no local backup (new
// machine) → bundle blob must always be written.
func TestCloudPull_OptionA_LocalNotExist_WritesBundleBlob(t *testing.T) {
	bundleBlob := credentialBlob("bundle-token", "bundle-rt", time.Now().Add(time.Hour))
	passphrase := "test-pass"

	cleanup := writeBundleFile(t, makeBundle([]cloudsync.BundleAccount{
		{Number: 1, Email: "a@example.com", CredentialBlob: string(bundleBlob)},
	}), passphrase)
	defer cleanup()

	bak := &pullTestBackupStore{blobs: map[int]domain.CredentialBlob{}}
	reg := &pullTestRegistry{reg: &domain.Registry{
		Accounts: map[int]*domain.Account{},
		Sequence: []int{},
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
	if got := bak.get(1); string(got) != string(bundleBlob) {
		t.Fatalf("expected bundle blob on new machine, got %q", got)
	}
}

// TestCloudPull_OptionA_SameExpiresAt_BundleWins — tie → bundle wins.
func TestCloudPull_OptionA_SameExpiresAt_BundleWins(t *testing.T) {
	fixed := time.Now().Add(time.Hour)
	bundleBlob := credentialBlob("bundle-token", "bundle-rt", fixed)
	localBlob := credentialBlob("local-token", "local-rt", fixed)
	passphrase := "test-pass"

	cleanup := writeBundleFile(t, makeBundle([]cloudsync.BundleAccount{
		{Number: 1, Email: "a@example.com", CredentialBlob: string(bundleBlob)},
	}), passphrase)
	defer cleanup()

	bak := &pullTestBackupStore{blobs: map[int]domain.CredentialBlob{1: localBlob}}
	reg := &pullTestRegistry{reg: &domain.Registry{Accounts: map[int]*domain.Account{}, Sequence: []int{}}}

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
	if got := bak.get(1); string(got) != string(bundleBlob) {
		t.Fatalf("expected bundle to win on tie, got %q", got)
	}
}

// TestCloudPull_R6_OneAccountWriteError_OthersSucceed_RegistrySaved — one
// keychain write failure must not abort the restore for other accounts, and the
// registry must be saved for the successful ones.
func TestCloudPull_R6_OneAccountWriteError_OthersSucceed_RegistrySaved(t *testing.T) {
	blob1 := credentialBlob("t1", "r1", time.Now().Add(time.Hour))
	blob2 := credentialBlob("t2", "r2", time.Now().Add(time.Hour))
	passphrase := "test-pass"

	cleanup := writeBundleFile(t, makeBundle([]cloudsync.BundleAccount{
		{Number: 1, Email: "a1@example.com", CredentialBlob: string(blob1)},
		{Number: 2, Email: "a2@example.com", CredentialBlob: string(blob2)},
	}), passphrase)
	defer cleanup()

	bak := &pullTestBackupStore{
		blobs:    map[int]domain.CredentialBlob{},
		writeErrs: map[int]error{1: errors.New("keychain write failed")},
	}
	reg := &pullTestRegistry{reg: &domain.Registry{Accounts: map[int]*domain.Account{}, Sequence: []int{}}}

	svc := &Service{
		Backup:     bak,
		Registry:   reg,
		Lock:       &pushTestLock{},
		Refresh:    &pullTestRefresher{err: errors.New("refresh disabled")},
		MCPSecrets: pullTestMCPSecretStore{},
	}
	err := svc.CloudPull(context.Background(), passphrase)
	if err == nil {
		t.Fatal("expected partial-failure error, got nil")
	}
	if !strings.Contains(err.Error(), "partial restore") {
		t.Fatalf("error should mention partial restore: %v", err)
	}

	// Account 2 must be written.
	if got := bak.get(2); string(got) != string(blob2) {
		t.Fatalf("account 2 should succeed, blobs: %v", bak.blobs)
	}

	// Registry must be saved with account 2 present.
	if reg.saveCalls == 0 {
		t.Fatal("Registry.Save must be called even when some accounts fail")
	}
	if _, ok := reg.reg.Accounts[2]; !ok {
		t.Fatal("account 2 must be in registry after partial restore")
	}
	if _, ok := reg.reg.Accounts[1]; ok {
		t.Fatal("failed account 1 must not be in registry")
	}
}

// TestCloudPull_R1_RefreshFiredAfterSave — after a successful pull, a background
// RefreshAllTokens must be triggered. We verify this by waiting briefly and
// checking the call counter.
func TestCloudPull_R1_RefreshFiredAfterSave(t *testing.T) {
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

	// Give the background goroutine time to run.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt64(&refresher.calls) > 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("RefreshAllTokens was not called in background after successful pull")
}
