package usecase

import (
	"context"
	"errors"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

type listTestLiveStore struct {
	readCount int
}

func (s *listTestLiveStore) Read(context.Context) (domain.CredentialBlob, error) {
	s.readCount++
	return "", errors.New("live keychain should not be read")
}

func (s *listTestLiveStore) Write(context.Context, domain.CredentialBlob) error {
	return nil
}

type listTestBackupStore struct {
	blobs  map[int]domain.CredentialBlob
	writes map[int]domain.CredentialBlob
}

func (s *listTestBackupStore) Read(_ context.Context, accountNum int, _ string) (domain.CredentialBlob, error) {
	return s.blobs[accountNum], nil
}

func (s *listTestBackupStore) Write(_ context.Context, accountNum int, _ string, blob domain.CredentialBlob) error {
	s.blobs[accountNum] = blob
	s.writes[accountNum] = blob
	return nil
}

func (s *listTestBackupStore) Delete(context.Context, int, string) error {
	return nil
}

type listTestRegistryStore struct {
	reg *domain.Registry
}

func (s listTestRegistryStore) Load(context.Context) (*domain.Registry, error) {
	return s.reg, nil
}

func (s listTestRegistryStore) Save(context.Context, *domain.Registry) error {
	return nil
}

type listTestUsageFetcher struct {
	mu     sync.Mutex
	tokens []string
}

func (f *listTestUsageFetcher) Fetch(_ context.Context, accessToken string) (*domain.Usage, error) {
	f.mu.Lock()
	f.tokens = append(f.tokens, accessToken)
	f.mu.Unlock()
	return &domain.Usage{
		FiveHour:  &domain.Window{UtilizationPct: 0.25, ResetsAt: time.Now().Add(time.Hour)},
		FetchedAt: time.Now(),
	}, nil
}

type listTestTokenRefresher struct {
	mu    sync.Mutex
	calls int
	fresh *domain.OAuthPayload
	err   error
}

func (r *listTestTokenRefresher) Refresh(context.Context, string) (*domain.OAuthPayload, error) {
	r.mu.Lock()
	r.calls++
	r.mu.Unlock()
	return r.fresh, r.err
}

func TestListAccountsUsesBackupForActiveAccount(t *testing.T) {
	live := &listTestLiveStore{}
	backup := &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			1: credentialBlob("active-token", "active-refresh", time.Now().Add(time.Hour)),
		},
		writes: map[int]domain.CredentialBlob{},
	}
	usage := &listTestUsageFetcher{}

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
		Usage:   usage,
		Refresh: &listTestTokenRefresher{},
	}

	res, err := svc.ListAccounts(context.Background())
	if err != nil {
		t.Fatalf("ListAccounts returned error: %v", err)
	}
	if live.readCount != 0 {
		t.Fatalf("active listing read live keychain %d time(s)", live.readCount)
	}
	if len(res.Accounts) != 1 || !res.Accounts[0].IsActive || res.Accounts[0].Usage == nil {
		t.Fatalf("unexpected account view: %+v", res.Accounts)
	}
	if len(usage.tokens) != 1 || usage.tokens[0] != "active-token" {
		t.Fatalf("usage token = %v, want active backup token", usage.tokens)
	}
}

func TestListAccountsShowsConfigActiveAccountWhenRegistryDrifts(t *testing.T) {
	backup := &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			1: credentialBlob("registry-token", "registry-refresh", time.Now().Add(time.Hour)),
			2: credentialBlob("config-token", "config-refresh", time.Now().Add(time.Hour)),
		},
		writes: map[int]domain.CredentialBlob{},
	}
	svc := &Service{
		Backup: backup,
		Config: switchTestConfigStore{cfg: &domain.ClaudeConfig{
			OAuthAccount: &domain.OAuthAccount{
				EmailAddress:     "config@example.com",
				OrganizationUUID: "config-org",
			},
		}},
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{1, 2},
			Accounts: map[int]*domain.Account{
				1: {Number: 1, Email: "registry@example.com", OrganizationUUID: "registry-org"},
				2: {Number: 2, Email: "config@example.com", OrganizationUUID: "config-org"},
			},
		}},
		Usage:   &listTestUsageFetcher{},
		Refresh: &listTestTokenRefresher{},
	}

	res, err := svc.ListAccounts(context.Background())
	if err != nil {
		t.Fatalf("ListAccounts returned error: %v", err)
	}
	if res.ActiveAccountNumber != 2 {
		t.Fatalf("active account number = %d, want config account 2", res.ActiveAccountNumber)
	}
	if res.Accounts[0].IsActive || !res.Accounts[1].IsActive {
		t.Fatalf("active views = %+v, want config account active", res.Accounts)
	}
}

func TestListAccountsRefreshesExpiredActiveBackupWithoutLiveRead(t *testing.T) {
	live := &listTestLiveStore{}
	backup := &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			1: credentialBlob("expired-token", "refresh-token", time.Now().Add(-time.Hour)),
		},
		writes: map[int]domain.CredentialBlob{},
	}
	usage := &listTestUsageFetcher{}
	refresh := &listTestTokenRefresher{
		fresh: &domain.OAuthPayload{
			AccessToken:  "fresh-token",
			RefreshToken: "refresh-token",
			ExpiresAt:    time.Now().Add(time.Hour).UnixMilli(),
		},
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
		Usage:   usage,
		Refresh: refresh,
	}

	if _, err := svc.ListAccounts(context.Background()); err != nil {
		t.Fatalf("ListAccounts returned error: %v", err)
	}
	if live.readCount != 0 {
		t.Fatalf("active listing read live keychain %d time(s)", live.readCount)
	}
	if refresh.calls != 1 {
		t.Fatalf("refresh calls = %d, want 1", refresh.calls)
	}
	if _, ok := backup.writes[1]; !ok {
		t.Fatal("expired active backup was not persisted after refresh")
	}
	if len(usage.tokens) != 1 || usage.tokens[0] != "fresh-token" {
		t.Fatalf("usage token = %v, want refreshed token", usage.tokens)
	}
}

func TestListAccountsFlagsInactiveAccountWhenExpiredBackupCannotRefresh(t *testing.T) {
	backup := &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			1: credentialBlob("active-token", "active-refresh", time.Now().Add(time.Hour)),
			2: credentialBlob("stale-token", "revoked-refresh", time.Now().Add(-time.Hour)),
		},
		writes: map[int]domain.CredentialBlob{},
	}
	usage := &listTestUsageFetcher{}
	svc := &Service{
		Backup: backup,
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{1, 2},
			Accounts: map[int]*domain.Account{
				1: {Number: 1, Email: "active@example.com"},
				2: {Number: 2, Email: "target@example.com"},
			},
		}},
		Usage:   usage,
		Refresh: &listTestTokenRefresher{err: errors.New("oauth refresh 400 invalid_grant")},
	}

	res, err := svc.ListAccounts(context.Background())
	if err != nil {
		t.Fatalf("ListAccounts returned error: %v", err)
	}
	if len(res.Accounts) != 2 {
		t.Fatalf("account count = %d, want 2", len(res.Accounts))
	}
	target := res.Accounts[1]
	if target.CredentialState != "needs_login" {
		t.Fatalf("credential state = %q, want needs_login", target.CredentialState)
	}
	if target.CredentialError == "" {
		t.Fatal("credential refresh failure detail missing")
	}
	if target.Usage == nil {
		t.Fatal("usage should still render from stored access token when reachable")
	}
}

func credentialBlob(accessToken, refreshToken string, expiresAt time.Time) domain.CredentialBlob {
	return domain.CredentialBlob(`{"claudeAiOauth":{"accessToken":"` + accessToken + `","refreshToken":"` + refreshToken + `","expiresAt":` + expiresMillis(expiresAt) + `}}`)
}

func expiresMillis(t time.Time) string {
	return strconv.FormatInt(t.UnixMilli(), 10)
}
