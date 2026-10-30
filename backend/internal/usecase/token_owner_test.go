package usecase

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// ownerProfile maps access tokens to the account email Anthropic reports.
type ownerProfile struct {
	owners map[string]string
	err    error
}

func (p ownerProfile) Identity(_ context.Context, access string) (*domain.TokenIdentity, error) {
	if p.err != nil {
		return nil, p.err
	}
	email, ok := p.owners[access]
	if !ok {
		return nil, errors.New("unknown token")
	}
	return &domain.TokenIdentity{Email: email}, nil
}

// Config names account 1 but live holds a stranger's freshly rotated token,
// which no backup carries yet: the heal must not copy it over account 1.
func TestHealSkipsLiveTokenOfAnotherAccount(t *testing.T) {
	live := credentialBlob("stranger-access", "stranger-rotated", time.Now().Add(time.Hour))
	backup := healBackups()
	svc := healTestService(live, "one@example.com", backup)
	svc.Profile = ownerProfile{owners: map[string]string{"stranger-access": "stranger@example.com"}}

	if _, err := svc.ListAccountsMetadata(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(backup.writes) != 0 {
		t.Fatalf("healed from another account's token: %v", backup.writes)
	}
}

func TestHealSkipsWhenTokenOwnerUnknown(t *testing.T) {
	backup := healBackups()
	svc := healTestService(credentialBlob("a2", "r2", time.Now().Add(time.Hour)), "one@example.com", backup)
	svc.Profile = ownerProfile{err: errors.New("network down")}

	if _, err := svc.ListAccountsMetadata(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(backup.writes) != 0 {
		t.Fatalf("healed without proof of owner: %v", backup.writes)
	}
}

func TestHealProceedsWhenTokenIsAccounts(t *testing.T) {
	live := credentialBlob("a2", "r2", time.Now().Add(time.Hour))
	backup := healBackups()
	svc := healTestService(live, "one@example.com", backup)
	svc.Profile = ownerProfile{owners: map[string]string{"a2": "ONE@example.com"}}

	if _, err := svc.ListAccountsMetadata(context.Background()); err != nil {
		t.Fatal(err)
	}
	if backup.writes[1] != live {
		t.Fatalf("active backup = %q, want live credential", backup.writes[1])
	}
}

func ownerUsageService(live domain.CredentialBlob, profile ownerProfile) *Service {
	backup := &listTestBackupStore{
		blobs:  map[int]domain.CredentialBlob{1: live},
		writes: map[int]domain.CredentialBlob{},
	}
	svc := healTestService(live, "one@example.com", backup)
	svc.Registry = listTestRegistryStore{reg: &domain.Registry{
		ActiveAccountNumber: 1,
		Sequence:            []int{1},
		Accounts:            map[int]*domain.Account{1: {Number: 1, Email: "one@example.com"}},
	}}
	svc.Usage = &listTestUsageFetcher{}
	svc.Profile = profile
	return svc
}

// The active row must not show usage read with another account's token.
func TestListHidesUsageOfAnotherAccountsToken(t *testing.T) {
	live := credentialBlob("stranger-access", "rs", time.Now().Add(time.Hour))
	svc := ownerUsageService(live, ownerProfile{owners: map[string]string{"stranger-access": "stranger@example.com"}})

	res, err := svc.ListAccounts(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	v := res.Accounts[0]
	if v.Usage != nil {
		t.Fatalf("usage shown for another account's token: %+v", v.Usage)
	}
	if v.CredentialState != "needs_login" || !strings.Contains(v.CredentialError, "stranger@example.com") {
		t.Fatalf("state = %q / %q, want needs_login naming the owner", v.CredentialState, v.CredentialError)
	}
}

func TestListKeepsUsageWhenProfileUnreachable(t *testing.T) {
	live := credentialBlob("a", "r", time.Now().Add(time.Hour))
	svc := ownerUsageService(live, ownerProfile{err: errors.New("network down")})

	res, err := svc.ListAccounts(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.Accounts[0].Usage == nil {
		t.Fatal("usage dropped over an unreachable profile endpoint")
	}
}

// ~/.claude.json names the active account, but the live token is a
// stranger's: the periodic snapshot must not copy it into the backup.
func TestSnapshotActiveLiveRefusesTokenOfAnotherAccount(t *testing.T) {
	svc, backup, _ := snapshotTestService("active@example.com")
	svc.Profile = ownerProfile{owners: map[string]string{"live-token": "stranger@example.com"}}

	if err := svc.SnapshotActiveLive(context.Background()); !errors.Is(err, ErrLiveIdentityMismatch) {
		t.Fatalf("err = %v, want ErrLiveIdentityMismatch", err)
	}
	if len(backup.writes) != 0 {
		t.Fatalf("backup written: %v", backup.writes)
	}
}

// An unconfirmed owner (expired token, no network) keeps the snapshot:
// skipping it could lose a refresh token Claude Code rotated.
func TestSnapshotActiveLiveKeepsCopyingWhenOwnerUnknown(t *testing.T) {
	svc, backup, live := snapshotTestService("active@example.com")
	svc.Profile = ownerProfile{err: errors.New("network down")}

	if err := svc.SnapshotActiveLive(context.Background()); err != nil {
		t.Fatal(err)
	}
	if backup.writes[1] != live {
		t.Fatalf("backup = %q, want live", backup.writes[1])
	}
}

// Switching to the active account repairs a live login that is really a
// stranger's, even when that live token looks newer than the backup.
func TestSwitchToActiveReplacesLiveTokenOfAnotherAccount(t *testing.T) {
	strangerLive := credentialBlob("stranger-access", "stranger-refresh", time.Now().Add(3*time.Hour))
	live := &switchTestLiveStore{read: strangerLive}
	own := credentialBlob("own-access", "own-refresh", time.Now().Add(time.Hour))
	backup := &listTestBackupStore{blobs: map[int]domain.CredentialBlob{1: own}, writes: map[int]domain.CredentialBlob{}}
	acc := &domain.Account{Number: 1, Email: "active@example.com", OrganizationUUID: "active-org"}
	svc := &Service{
		Live:   live,
		Backup: backup,
		Config: switchTestConfigStore{cfg: &domain.ClaudeConfig{
			Raw:          map[string]any{},
			OAuthAccount: &domain.OAuthAccount{EmailAddress: acc.Email, OrganizationUUID: acc.OrganizationUUID},
		}},
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{1},
			Accounts:            map[int]*domain.Account{1: acc},
		}},
		Refresh: &listTestTokenRefresher{},
		Lock:    switchTestLock{},
		Profile: ownerProfile{owners: map[string]string{
			"stranger-access": "stranger@example.com",
			"own-access":      "active@example.com",
		}},
	}

	if err := svc.SwitchAccount(context.Background(), 1); err != nil {
		t.Fatalf("SwitchAccount(active): %v", err)
	}
	if live.written != own {
		t.Fatalf("live = %q, want the account's own backup installed", live.written)
	}
	if _, wrote := backup.writes[1]; wrote {
		t.Fatal("stranger's token copied into the backup")
	}
}
