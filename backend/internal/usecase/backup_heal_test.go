package usecase

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

type busyLock struct{}

func (busyLock) Acquire(context.Context) error { return errors.New("swap in progress") }
func (busyLock) Release() error                { return nil }

func healTestService(live domain.CredentialBlob, cfgEmail string, backup *listTestBackupStore) *Service {
	var cfg *domain.ClaudeConfig
	if cfgEmail != "" {
		cfg = &domain.ClaudeConfig{OAuthAccount: &domain.OAuthAccount{EmailAddress: cfgEmail}}
	}
	return &Service{
		Live:   &listTestLiveStore{blob: live},
		Backup: backup,
		Config: switchTestConfigStore{cfg: cfg},
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{1, 2},
			Accounts: map[int]*domain.Account{
				1: {Number: 1, Email: "one@example.com"},
				2: {Number: 2, Email: "two@example.com"},
			},
		}},
		Lock: switchTestLock{},
	}
}

func healBackups() *listTestBackupStore {
	return &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			1: credentialBlob("a1", "r1-revoked", time.Now().Add(-time.Hour)),
			2: credentialBlob("b", "rb", time.Now().Add(time.Hour)),
		},
		writes: map[int]domain.CredentialBlob{},
	}
}

func TestListAccountsHealsActiveBackupFromLive(t *testing.T) {
	live := credentialBlob("a2", "r2-rotated-by-claude", time.Now().Add(time.Hour))
	backup := healBackups()
	svc := healTestService(live, "one@example.com", backup)

	if _, err := svc.ListAccountsMetadata(context.Background()); err != nil {
		t.Fatal(err)
	}
	if backup.writes[1] != live {
		t.Fatalf("active backup = %q, want live credential", backup.writes[1])
	}
	if _, touched := backup.writes[2]; touched {
		t.Fatal("inactive backup must not be touched")
	}
}

func TestListAccountsSkipsHealWithoutIdentityProof(t *testing.T) {
	live := credentialBlob("x", "rx", time.Now().Add(time.Hour))
	for name, svc := range map[string]*Service{
		"no oauthAccount":   healTestService(live, "", healBackups()),
		"identity mismatch": healTestService(live, "stranger@example.com", healBackups()),
	} {
		if _, err := svc.ListAccountsMetadata(context.Background()); err != nil {
			t.Fatal(err)
		}
		if w := svc.Backup.(*listTestBackupStore).writes; len(w) != 0 {
			t.Fatalf("%s: wrote %v", name, w)
		}
	}
}

func TestListAccountsSkipsHealWhileSwapHoldsLock(t *testing.T) {
	backup := healBackups()
	svc := healTestService(credentialBlob("b", "rb", time.Now().Add(time.Hour)), "one@example.com", backup)
	svc.Lock = busyLock{}

	if _, err := svc.ListAccountsMetadata(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(backup.writes) != 0 {
		t.Fatalf("healed mid-swap: %v", backup.writes)
	}
}

func TestListAccountsSkipsHealWhenLiveUnusable(t *testing.T) {
	backup := healBackups()
	svc := healTestService(`{"claudeAiOauth":{"accessToken":"","refreshToken":""}}`, "one@example.com", backup)

	if _, err := svc.ListAccountsMetadata(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(backup.writes) != 0 {
		t.Fatalf("healed from unusable live: %v", backup.writes)
	}
}

// swapFinishesWhileWaiting completes a swap to account 2 (live and
// ~/.claude.json both switch) by the time the heal gets the lock.
type swapFinishesWhileWaiting struct {
	cfg  *domain.ClaudeConfig
	live *listTestLiveStore
	to   domain.CredentialBlob
}

func (l *swapFinishesWhileWaiting) Acquire(context.Context) error {
	l.cfg.OAuthAccount = &domain.OAuthAccount{EmailAddress: "two@example.com"}
	l.live.blob = l.to
	return nil
}
func (l *swapFinishesWhileWaiting) Release() error { return nil }

func TestHealRechecksIdentityAfterWaitingForSwap(t *testing.T) {
	backup := healBackups()
	svc := healTestService(credentialBlob("a2", "r2", time.Now().Add(time.Hour)), "one@example.com", backup)
	cfg := svc.Config.(switchTestConfigStore).cfg
	twoLive := credentialBlob("b2", "rb2", time.Now().Add(2*time.Hour))
	svc.Lock = &swapFinishesWhileWaiting{cfg: cfg, live: svc.Live.(*listTestLiveStore), to: twoLive}

	if _, err := svc.ListAccountsMetadata(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, wrote := backup.writes[1]; wrote {
		t.Fatal("account 2's login written into account 1's backup")
	}
	if backup.writes[2] != twoLive {
		t.Fatalf("account 2 backup = %q, want its live credential", backup.writes[2])
	}
}

func TestHealKeepsNewerBackup(t *testing.T) {
	backup := healBackups()
	backup.blobs[1] = credentialBlob("fresh-login", "fresh-refresh", time.Now().Add(2*time.Hour))
	svc := healTestService(credentialBlob("old-live", "old-refresh", time.Now().Add(time.Hour)), "one@example.com", backup)

	if _, err := svc.ListAccountsMetadata(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(backup.writes) != 0 {
		t.Fatalf("older live overwrote a newer backup: %v", backup.writes)
	}
}

// Claude Code's /login writes ~/.claude.json before the Keychain: for a
// moment the config names the new account while live still holds the old
// one's tokens.
func TestHealSkipsLiveThatBelongsToAnotherAccount(t *testing.T) {
	backup := healBackups()
	// Live is still account 2's login (same refresh token as its backup),
	// but ~/.claude.json already names account 1.
	backup.blobs[2] = credentialBlob("b", "rb", time.Now().Add(time.Hour))
	svc := healTestService(credentialBlob("b", "rb", time.Now().Add(time.Hour)), "one@example.com", backup)

	if _, err := svc.ListAccountsMetadata(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, wrote := backup.writes[1]; wrote {
		t.Fatal("account 2's live login written into account 1's backup")
	}
}
