package usecase

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/oauth"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// perAccountRefresher routes Refresh by refresh_token string so each account
// in a RefreshAllTokens run can be configured independently (rate-limited,
// hard-fail, success).
type perAccountRefresher struct {
	mu      sync.Mutex
	results map[string]refreshOutcome
	calls   map[string]int
}

type refreshOutcome struct {
	fresh *domain.OAuthPayload
	err   error
}

func (r *perAccountRefresher) Refresh(_ context.Context, refreshToken string) (*domain.OAuthPayload, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.calls == nil {
		r.calls = map[string]int{}
	}
	r.calls[refreshToken]++
	out, ok := r.results[refreshToken]
	if !ok {
		return nil, errors.New("unexpected refresh token in test")
	}
	return out.fresh, out.err
}

func TestRefreshAllTokens_RateLimitedTaggedSeparately(t *testing.T) {
	expiresMS := time.Now().Add(time.Hour).UnixMilli()
	backup := &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			2: credentialBlob("a2", "ref-2", time.Now().Add(time.Hour)),
			3: credentialBlob("a3", "ref-3", time.Now().Add(time.Hour)),
		},
		writes: map[int]domain.CredentialBlob{},
	}
	refresher := &perAccountRefresher{results: map[string]refreshOutcome{
		"ref-2": {fresh: &domain.OAuthPayload{
			AccessToken: "a2-new", RefreshToken: "ref-2-new", ExpiresAt: expiresMS,
		}},
		"ref-3": {err: &oauth.RateLimitedError{RetryAfter: "60"}},
	}}
	svc := &Service{
		Live:   &listTestLiveStore{},
		Backup: backup,
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{2, 3},
			Accounts: map[int]*domain.Account{
				2: {Number: 2, Email: "two@example.com"},
				3: {Number: 3, Email: "three@example.com"},
			},
		}},
		Refresh: refresher,
	}

	err := svc.RefreshAllTokens(context.Background())
	if err == nil {
		t.Fatal("expected non-nil error (one account rate-limited)")
	}
	msg := err.Error()
	if !strings.HasPrefix(msg, "rate limited:") {
		t.Fatalf("error = %q, want prefix 'rate limited:' (no hard failures present)", msg)
	}
	if strings.Contains(msg, "partial refresh failures") {
		t.Fatalf("error = %q, must not bundle RL into 'partial refresh failures'", msg)
	}
	if !strings.Contains(msg, "account 3") {
		t.Fatalf("error = %q, want to name account 3", msg)
	}
	if _, wrote2 := backup.writes[2]; !wrote2 {
		t.Fatal("account 2 (success) should have been written to keychain")
	}
	if _, wrote3 := backup.writes[3]; wrote3 {
		t.Fatal("account 3 (rate-limited) must not have been written")
	}
}

func TestRefreshAllTokens_HardAndRateLimitedReportedSeparately(t *testing.T) {
	backup := &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			2: credentialBlob("a2", "ref-2", time.Now().Add(time.Hour)),
			3: credentialBlob("a3", "ref-3", time.Now().Add(time.Hour)),
		},
		writes: map[int]domain.CredentialBlob{},
	}
	refresher := &perAccountRefresher{results: map[string]refreshOutcome{
		"ref-2": {err: errors.New("oauth refresh 400: invalid_grant")},
		"ref-3": {err: &oauth.RateLimitedError{RetryAfter: "30"}},
	}}
	svc := &Service{
		Live:   &listTestLiveStore{},
		Backup: backup,
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{2, 3},
			Accounts: map[int]*domain.Account{
				2: {Number: 2, Email: "two@example.com"},
				3: {Number: 3, Email: "three@example.com"},
			},
		}},
		Refresh: refresher,
	}

	err := svc.RefreshAllTokens(context.Background())
	if err == nil {
		t.Fatal("expected non-nil error")
	}
	msg := err.Error()
	if !strings.Contains(msg, "partial refresh failures") {
		t.Fatalf("error = %q, want to contain 'partial refresh failures'", msg)
	}
	if !strings.Contains(msg, "rate limited") {
		t.Fatalf("error = %q, want to contain 'rate limited'", msg)
	}
}
