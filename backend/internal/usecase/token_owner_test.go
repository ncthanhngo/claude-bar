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
