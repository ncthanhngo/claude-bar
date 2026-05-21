package usecase

import (
	"context"
	"errors"
	"strconv"
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
	tokens []string
}

func (f *listTestUsageFetcher) Fetch(_ context.Context, accessToken string) (*domain.Usage, error) {
	f.tokens = append(f.tokens, accessToken)
	return &domain.Usage{
		FiveHour:  &domain.Window{UtilizationPct: 0.25, ResetsAt: time.Now().Add(time.Hour)},
		FetchedAt: time.Now(),
	}, nil
}

type listTestTokenRefresher struct {
	calls int
	fresh *domain.OAuthPayload
}

func (r *listTestTokenRefresher) Refresh(context.Context, string) (*domain.OAuthPayload, error) {
	r.calls++
	return r.fresh, nil
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

func credentialBlob(accessToken, refreshToken string, expiresAt time.Time) domain.CredentialBlob {
	return domain.CredentialBlob(`{"claudeAiOauth":{"accessToken":"` + accessToken + `","refreshToken":"` + refreshToken + `","expiresAt":` + expiresMillis(expiresAt) + `}}`)
}

func expiresMillis(t time.Time) string {
	return strconv.FormatInt(t.UnixMilli(), 10)
}
