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

// verifyUsageFetcher records call order and lets each call return a configured
// (usage, err) pair so 401-then-OK retries can be exercised. Mutex matches
// listTestUsageFetcher's pattern — VerifyAccounts spawns one goroutine per
// account, so concurrent Fetch calls are possible whenever a test uses more
// than one account in its registry.
type verifyUsageFetcher struct {
	mu      sync.Mutex
	calls   int
	tokens  []string
	results []verifyUsageResult
}

type verifyUsageResult struct {
	usage *domain.Usage
	err   error
}

func (f *verifyUsageFetcher) Fetch(_ context.Context, accessToken string) (*domain.Usage, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	idx := f.calls
	f.calls++
	f.tokens = append(f.tokens, accessToken)
	if idx >= len(f.results) {
		return &domain.Usage{FetchedAt: time.Now()}, nil
	}
	return f.results[idx].usage, f.results[idx].err
}

// verifyTokenRefresher counts refresh calls and returns a fixed fresh payload
// (or err) so we can assert "no rotation happened" vs "exactly one rotation".
type verifyTokenRefresher struct {
	mu    sync.Mutex
	calls int
	fresh *domain.OAuthPayload
	err   error
}

func (r *verifyTokenRefresher) Refresh(context.Context, string) (*domain.OAuthPayload, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls++
	return r.fresh, r.err
}

func buildVerifyService(
	blob domain.CredentialBlob,
	usage *verifyUsageFetcher,
	refresh *verifyTokenRefresher,
) (*Service, *listTestBackupStore) {
	backup := &listTestBackupStore{
		blobs:  map[int]domain.CredentialBlob{2: blob},
		writes: map[int]domain.CredentialBlob{},
	}
	svc := &Service{
		Live:   &listTestLiveStore{},
		Backup: backup,
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{2},
			Accounts: map[int]*domain.Account{
				2: {Number: 2, Email: "inactive@example.com"},
			},
		}},
		Usage:   usage,
		Refresh: refresh,
	}
	return svc, backup
}

func findCheck(checks []domain.CheckResult, name string) *domain.CheckResult {
	for i := range checks {
		if checks[i].Name == name {
			return &checks[i]
		}
	}
	return nil
}

// Fresh access token + usage 200 → no rotation, swap_ready true.
func TestVerifyAccounts_FreshAccess_NoRotation(t *testing.T) {
	blob := credentialBlob("fresh-access", "ref-1", time.Now().Add(time.Hour))
	usage := &verifyUsageFetcher{}
	refresh := &verifyTokenRefresher{}
	svc, backup := buildVerifyService(blob, usage, refresh)

	report, err := svc.VerifyAccounts(context.Background())
	if err != nil {
		t.Fatalf("VerifyAccounts error: %v", err)
	}
	if report.Ready != 1 || report.Failed != 0 {
		t.Fatalf("ready=%d failed=%d, want 1/0", report.Ready, report.Failed)
	}
	if refresh.calls != 0 {
		t.Fatalf("refresh.calls = %d, want 0 (lazy path must not rotate fresh tokens)", refresh.calls)
	}
	if usage.calls != 1 || usage.tokens[0] != "fresh-access" {
		t.Fatalf("usage tokens = %v, want one call with fresh-access", usage.tokens)
	}
	if _, wrote := backup.writes[2]; wrote {
		t.Fatal("backup keychain was written despite fresh token")
	}
	tr := findCheck(report.Results[0].Checks, "token_refresh")
	if tr == nil || !tr.Skipped {
		t.Fatalf("token_refresh check = %+v, want skipped row", tr)
	}
}

// Expired access token → exactly one rotation, swap_ready true.
func TestVerifyAccounts_ExpiredAccess_OneRotation(t *testing.T) {
	blob := credentialBlob("expired-access", "ref-1", time.Now().Add(-time.Hour))
	usage := &verifyUsageFetcher{}
	refresh := &verifyTokenRefresher{fresh: &domain.OAuthPayload{
		AccessToken:  "rotated-access",
		RefreshToken: "ref-2",
		ExpiresAt:    time.Now().Add(time.Hour).UnixMilli(),
	}}
	svc, backup := buildVerifyService(blob, usage, refresh)

	report, err := svc.VerifyAccounts(context.Background())
	if err != nil {
		t.Fatalf("VerifyAccounts error: %v", err)
	}
	if report.Ready != 1 {
		t.Fatalf("ready=%d, want 1", report.Ready)
	}
	if refresh.calls != 1 {
		t.Fatalf("refresh.calls = %d, want 1 (expired path must rotate)", refresh.calls)
	}
	if len(usage.tokens) != 1 || usage.tokens[0] != "rotated-access" {
		t.Fatalf("usage tokens = %v, want one call with rotated-access", usage.tokens)
	}
	if _, wrote := backup.writes[2]; !wrote {
		t.Fatal("rotated blob was not written back to keychain")
	}
	tr := findCheck(report.Results[0].Checks, "token_refresh")
	if tr == nil || tr.Skipped || !tr.Passed {
		t.Fatalf("token_refresh check = %+v, want passed", tr)
	}
}

// Access still valid by timestamp but server rejects it (401) → exactly one
// rotation, retry succeeds, swap_ready true, token_refresh row promoted from
// "skipped" to "passed".
func TestVerifyAccounts_FreshAccessUsage401_RetryRotates(t *testing.T) {
	blob := credentialBlob("stale-access", "ref-1", time.Now().Add(time.Hour))
	usage := &verifyUsageFetcher{
		results: []verifyUsageResult{
			{err: &oauth.UnauthorizedError{Body: "revoked"}},
			{usage: &domain.Usage{FetchedAt: time.Now()}},
		},
	}
	refresh := &verifyTokenRefresher{fresh: &domain.OAuthPayload{
		AccessToken:  "rotated-access",
		RefreshToken: "ref-2",
		ExpiresAt:    time.Now().Add(time.Hour).UnixMilli(),
	}}
	svc, _ := buildVerifyService(blob, usage, refresh)

	report, err := svc.VerifyAccounts(context.Background())
	if err != nil {
		t.Fatalf("VerifyAccounts error: %v", err)
	}
	if report.Ready != 1 {
		t.Fatalf("ready=%d, want 1", report.Ready)
	}
	if refresh.calls != 1 {
		t.Fatalf("refresh.calls = %d, want exactly 1 retry rotation", refresh.calls)
	}
	if len(usage.tokens) != 2 || usage.tokens[0] != "stale-access" || usage.tokens[1] != "rotated-access" {
		t.Fatalf("usage tokens = %v, want [stale-access rotated-access]", usage.tokens)
	}
	tr := findCheck(report.Results[0].Checks, "token_refresh")
	if tr == nil || tr.Skipped || !tr.Passed {
		t.Fatalf("token_refresh check = %+v, want passed after on-401 rotation", tr)
	}
	// Exactly one token_refresh row — the lazy "skipped" entry must be
	// overwritten, not duplicated, when rotation actually happens.
	count := 0
	for _, c := range report.Results[0].Checks {
		if c.Name == "token_refresh" {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("token_refresh appears %d times, want 1", count)
	}
}

// Expired access + refresh endpoint rate-limited → token_refresh recorded as
// skipped (transient), no retry storm, swap_ready falls back to usage outcome
// (mock returns 200, so swap_ready true — soft-pass parity with usage 429).
func TestVerifyAccounts_RefreshRateLimited_SoftPasses(t *testing.T) {
	blob := credentialBlob("expired-access", "ref-1", time.Now().Add(-time.Hour))
	usage := &verifyUsageFetcher{}
	refresh := &verifyTokenRefresher{err: &oauth.RateLimitedError{RetryAfter: "30"}}
	svc, backup := buildVerifyService(blob, usage, refresh)

	report, err := svc.VerifyAccounts(context.Background())
	if err != nil {
		t.Fatalf("VerifyAccounts error: %v", err)
	}
	if refresh.calls != 1 {
		t.Fatalf("refresh.calls = %d, want exactly 1 (no retry storm on RL)", refresh.calls)
	}
	if len(usage.tokens) != 1 || usage.tokens[0] != "expired-access" {
		t.Fatalf("usage tokens = %v, want one call with expired-access (no rotation)", usage.tokens)
	}
	if _, wrote := backup.writes[2]; wrote {
		t.Fatal("backup keychain was written despite rate-limited refresh")
	}
	if report.Ready != 1 {
		t.Fatalf("ready=%d, want 1 (soft-pass: usage 200 with old access)", report.Ready)
	}
	tr := findCheck(report.Results[0].Checks, "token_refresh")
	if tr == nil || !tr.Skipped {
		t.Fatalf("token_refresh check = %+v, want skipped (rate limited)", tr)
	}
	if !strings.Contains(tr.Detail, "rate limited") {
		t.Fatalf("token_refresh detail = %q, want to contain 'rate limited'", tr.Detail)
	}
}

// Expired access + refresh rate-limited + usage rejects the expired token →
// honest cascade: token_refresh skipped (rate limited), usage_reachable failed
// (401 with old access), SwapReady=false, no extra retry attempt.
func TestVerifyAccounts_RefreshRateLimitedAndUsage401_NotReady(t *testing.T) {
	blob := credentialBlob("expired-access", "ref-1", time.Now().Add(-time.Hour))
	usage := &verifyUsageFetcher{
		results: []verifyUsageResult{
			{err: &oauth.UnauthorizedError{Body: "expired"}},
		},
	}
	refresh := &verifyTokenRefresher{err: &oauth.RateLimitedError{RetryAfter: "30"}}
	svc, _ := buildVerifyService(blob, usage, refresh)

	report, err := svc.VerifyAccounts(context.Background())
	if err != nil {
		t.Fatalf("VerifyAccounts error: %v", err)
	}
	if report.Ready != 0 || report.Failed != 1 {
		t.Fatalf("ready=%d failed=%d, want 0/1", report.Ready, report.Failed)
	}
	if refresh.calls != 1 {
		t.Fatalf("refresh.calls = %d, want exactly 1 (no retry storm on RL+401)", refresh.calls)
	}
	if usage.calls != 1 || usage.tokens[0] != "expired-access" {
		t.Fatalf("usage tokens = %v, want one call with expired-access only", usage.tokens)
	}
	tr := findCheck(report.Results[0].Checks, "token_refresh")
	if tr == nil || !tr.Skipped || !strings.Contains(tr.Detail, "rate limited") {
		t.Fatalf("token_refresh check = %+v, want skipped (rate limited)", tr)
	}
	ur := findCheck(report.Results[0].Checks, "usage_reachable")
	if ur == nil || ur.Passed || ur.Skipped {
		t.Fatalf("usage_reachable check = %+v, want failed (401 with expired access)", ur)
	}
}

// Expired access + refresh endpoint fails → not swap_ready, no retry loop.
func TestVerifyAccounts_RefreshFails_NotReady(t *testing.T) {
	blob := credentialBlob("expired-access", "ref-1", time.Now().Add(-time.Hour))
	usage := &verifyUsageFetcher{}
	refresh := &verifyTokenRefresher{err: errors.New("invalid_grant")}
	svc, _ := buildVerifyService(blob, usage, refresh)

	report, err := svc.VerifyAccounts(context.Background())
	if err != nil {
		t.Fatalf("VerifyAccounts error: %v", err)
	}
	if report.Ready != 0 || report.Failed != 1 {
		t.Fatalf("ready=%d failed=%d, want 0/1", report.Ready, report.Failed)
	}
	if refresh.calls != 1 {
		t.Fatalf("refresh.calls = %d, want exactly 1 (no retry storm)", refresh.calls)
	}
	if usage.calls != 0 {
		t.Fatalf("usage.calls = %d, want 0 — must not reach usage when refresh fails", usage.calls)
	}
	tr := findCheck(report.Results[0].Checks, "token_refresh")
	if tr == nil || tr.Passed || tr.Skipped {
		t.Fatalf("token_refresh check = %+v, want failed", tr)
	}
}
