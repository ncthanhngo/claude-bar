package keychain

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// fakeStore is a port.MCPSecretStore implementation backed by an in-memory
// map plus a sentinel slot. Used by migration tests because the real store
// hits /usr/bin/security.
type fakeStore struct {
	secrets  map[fakeKey]string
	sentinel time.Time // zero value = not yet migrated
	readErr  error
	writeErr error
}

type fakeKey struct {
	account int
	service domain.MCPService
}

func newFakeStore() *fakeStore {
	return &fakeStore{secrets: map[fakeKey]string{}}
}

func (f *fakeStore) Read(_ context.Context, n int, s domain.MCPService) (string, error) {
	if f.readErr != nil {
		return "", f.readErr
	}
	return f.secrets[fakeKey{n, s}], nil
}
func (f *fakeStore) Write(_ context.Context, n int, s domain.MCPService, p string) error {
	if f.writeErr != nil {
		return f.writeErr
	}
	f.secrets[fakeKey{n, s}] = p
	return nil
}
func (f *fakeStore) Delete(_ context.Context, n int, s domain.MCPService) error {
	delete(f.secrets, fakeKey{n, s})
	return nil
}
func (f *fakeStore) DeleteAll(_ context.Context, n int) error {
	for k := range f.secrets {
		if k.account == n {
			delete(f.secrets, k)
		}
	}
	return nil
}
func (f *fakeStore) IsMigratedToShared(_ context.Context) (bool, error) {
	return !f.sentinel.IsZero(), nil
}
func (f *fakeStore) MarkMigratedToShared(_ context.Context, ts time.Time) error {
	f.sentinel = ts
	return nil
}

func registryWithAccount(num int, connectedAt time.Time, withConnector bool) *domain.Account {
	a := &domain.Account{Number: num, Email: "a@b.c", CreatedAt: time.Now()}
	if withConnector {
		a.MCPConnectors = domain.AccountConnectors{
			domain.MCPServiceSlack: &domain.MCPConnector{Enabled: true, ConnectedAt: connectedAt},
		}
	}
	return a
}

func TestMigrateToShared_NoCandidates(t *testing.T) {
	store := newFakeStore()
	reg := domain.NewRegistry()

	out := MigrateToSharedMust(t, store, reg)

	if out.AlreadyDone {
		t.Fatal("first run must not report AlreadyDone")
	}
	for _, r := range out.ServiceResults {
		if r.Action != ActionNoOp {
			t.Errorf("svc=%s: want noop, got %s", r.Service, r.Action)
		}
		if r.CandidateCount != 0 {
			t.Errorf("svc=%s: want 0 candidates, got %d", r.Service, r.CandidateCount)
		}
	}
}

func TestMigrateToShared_SingleAccountCanonicalises(t *testing.T) {
	store := newFakeStore()
	store.secrets[fakeKey{1, domain.MCPServiceSlack}] = "xoxp-acct-1"

	reg := domain.NewRegistry()
	reg.Accounts[1] = registryWithAccount(1, time.Now(), true)

	out := MigrateToSharedMust(t, store, reg)

	got := findResult(out, domain.MCPServiceSlack)
	if got.Action != ActionCanonicalised {
		t.Fatalf("want canonicalised, got %s (err=%s)", got.Action, got.Error)
	}
	if got.WinningAccount != 1 {
		t.Errorf("winner: want 1, got %d", got.WinningAccount)
	}
	if store.secrets[fakeKey{0, domain.MCPServiceSlack}] != "xoxp-acct-1" {
		t.Errorf("shared slot not written: %q", store.secrets[fakeKey{0, domain.MCPServiceSlack}])
	}
	// Legacy entry preserved for rollback.
	if store.secrets[fakeKey{1, domain.MCPServiceSlack}] != "xoxp-acct-1" {
		t.Error("legacy entry must be preserved for rollback")
	}
}

func TestMigrateToShared_MostRecentConnectedAtWins(t *testing.T) {
	store := newFakeStore()
	store.secrets[fakeKey{1, domain.MCPServiceSlack}] = "xoxp-older"
	store.secrets[fakeKey{2, domain.MCPServiceSlack}] = "xoxp-newer"

	older := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	newer := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)

	reg := domain.NewRegistry()
	reg.Accounts[1] = registryWithAccount(1, older, true)
	reg.Accounts[2] = registryWithAccount(2, newer, true)

	out := MigrateToSharedMust(t, store, reg)

	got := findResult(out, domain.MCPServiceSlack)
	if got.Action != ActionCanonicalised {
		t.Fatalf("want canonicalised, got %s", got.Action)
	}
	if got.WinningAccount != 2 {
		t.Errorf("winner: want acct 2 (newer ConnectedAt), got %d", got.WinningAccount)
	}
	if store.secrets[fakeKey{0, domain.MCPServiceSlack}] != "xoxp-newer" {
		t.Errorf("wrong winning payload: %q", store.secrets[fakeKey{0, domain.MCPServiceSlack}])
	}
}

func TestMigrateToShared_LowestAccountWinsOnTie(t *testing.T) {
	store := newFakeStore()
	store.secrets[fakeKey{2, domain.MCPServiceSlack}] = "xoxp-acct-2"
	store.secrets[fakeKey{5, domain.MCPServiceSlack}] = "xoxp-acct-5"

	sameTime := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)
	reg := domain.NewRegistry()
	reg.Accounts[2] = registryWithAccount(2, sameTime, true)
	reg.Accounts[5] = registryWithAccount(5, sameTime, true)

	out := MigrateToSharedMust(t, store, reg)
	got := findResult(out, domain.MCPServiceSlack)
	if got.WinningAccount != 2 {
		t.Errorf("tie-break: want lowest (2), got %d", got.WinningAccount)
	}
}

func TestMigrateToShared_PreservesExistingShared(t *testing.T) {
	store := newFakeStore()
	store.secrets[fakeKey{0, domain.MCPServiceSlack}] = "xoxp-already-shared"
	store.secrets[fakeKey{1, domain.MCPServiceSlack}] = "xoxp-acct-1"

	reg := domain.NewRegistry()
	reg.Accounts[1] = registryWithAccount(1, time.Now(), true)

	out := MigrateToSharedMust(t, store, reg)
	got := findResult(out, domain.MCPServiceSlack)

	if got.Action != ActionKeptShared {
		t.Errorf("want kept-shared (don't clobber existing), got %s", got.Action)
	}
	if store.secrets[fakeKey{0, domain.MCPServiceSlack}] != "xoxp-already-shared" {
		t.Errorf("shared slot was overwritten: %q", store.secrets[fakeKey{0, domain.MCPServiceSlack}])
	}
}

func TestMigrateToShared_Idempotent(t *testing.T) {
	store := newFakeStore()
	store.secrets[fakeKey{1, domain.MCPServiceSlack}] = "xoxp-acct-1"
	reg := domain.NewRegistry()
	reg.Accounts[1] = registryWithAccount(1, time.Now(), true)

	first := MigrateToSharedMust(t, store, reg)
	if first.AlreadyDone {
		t.Fatal("first call must not be AlreadyDone")
	}
	if findResult(first, domain.MCPServiceSlack).Action != ActionCanonicalised {
		t.Fatal("first call should canonicalise")
	}

	// Second call: sentinel set, must short-circuit.
	second := MigrateToSharedMust(t, store, reg)
	if !second.AlreadyDone {
		t.Error("second call must report AlreadyDone")
	}
	if len(second.ServiceResults) != 0 {
		t.Errorf("AlreadyDone run must skip per-service work, got %d results", len(second.ServiceResults))
	}
}

func TestMigrateToShared_ReadFailureSurfaces(t *testing.T) {
	store := newFakeStore()
	store.readErr = errors.New("keychain locked")
	reg := domain.NewRegistry()
	reg.Accounts[1] = registryWithAccount(1, time.Now(), true)

	out := MigrateToSharedMust(t, store, reg)
	got := findResult(out, domain.MCPServiceSlack)
	if got.Action != ActionFailed {
		t.Errorf("want failed, got %s", got.Action)
	}
	if got.Error == "" {
		t.Error("error message must be populated on failure")
	}
}

func TestMigrateToShared_NilRegistryNoPanic(t *testing.T) {
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("panicked on nil registry: %v", r)
		}
	}()
	store := newFakeStore()
	out := MigrateToSharedMust(t, store, nil)
	for _, r := range out.ServiceResults {
		if r.Action != ActionNoOp {
			t.Errorf("nil registry: want noop on all services, got %s for %s", r.Action, r.Service)
		}
	}
}

// MigrateToSharedMust runs MigrateToShared and fails the test on a top-level
// error (typically a sentinel read/write failure). Per-service ActionFailed
// is NOT a top-level error — the caller inspects ServiceResults for that.
func MigrateToSharedMust(t *testing.T, store port.MCPSecretStore, reg *domain.Registry) MigrationOutcome {
	t.Helper()
	out, err := MigrateToShared(context.Background(), store, reg)
	if err != nil {
		t.Fatalf("MigrateToShared: %v", err)
	}
	return out
}

func TestMigrateToShared_FailureSkipsSentinelSoNextBootRetries(t *testing.T) {
	store := newFakeStore()
	store.secrets[fakeKey{1, domain.MCPServiceSlack}] = "xoxp-will-fail"
	store.readErr = errors.New("keychain locked")

	reg := domain.NewRegistry()
	reg.Accounts[1] = registryWithAccount(1, time.Now(), true)

	out := MigrateToSharedMust(t, store, reg)
	if findResult(out, domain.MCPServiceSlack).Action != ActionFailed {
		t.Fatal("setup: read should fail")
	}
	if !store.sentinel.IsZero() {
		t.Error("sentinel must NOT be written when any service fails (forces retry next boot)")
	}

	// Recover from failure, run again — sentinel must now be written.
	store.readErr = nil
	out2 := MigrateToSharedMust(t, store, reg)
	if out2.AlreadyDone {
		t.Fatal("second run after failure must not short-circuit (sentinel was not written)")
	}
	if store.sentinel.IsZero() {
		t.Error("sentinel must be written when all services succeed")
	}
}

func findResult(o MigrationOutcome, svc domain.MCPService) ServiceMigration {
	for _, r := range o.ServiceResults {
		if r.Service == svc {
			return r
		}
	}
	return ServiceMigration{}
}
