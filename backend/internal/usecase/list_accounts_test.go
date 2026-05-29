package usecase

import (
	"context"
	"errors"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/oauth"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

type listTestLiveStore struct {
	blob domain.CredentialBlob
	err  error
	// readCount tracks how many times Read was called; tests may assert on it.
	readCount int
}

func (s *listTestLiveStore) Read(context.Context) (domain.CredentialBlob, error) {
	s.readCount++
	return s.blob, s.err
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

func TestListAccountsUsesBackupTokenForUsageFetch(t *testing.T) {
	// The usage fetch must use the BACKUP token (not the live token) for
	// active accounts. Live is read for liveness inspection but the token
	// passed to Usage.Fetch must come from the backup store.
	liveBlob := credentialBlob("live-token", "live-refresh", time.Now().Add(time.Hour))
	live := &listTestLiveStore{blob: liveBlob}
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
	if len(res.Accounts) != 1 || !res.Accounts[0].IsActive || res.Accounts[0].Usage == nil {
		t.Fatalf("unexpected account view: %+v", res.Accounts)
	}
	// The backup token must be used for usage — NOT the live token.
	if len(usage.tokens) < 1 || usage.tokens[0] != "active-token" {
		t.Fatalf("usage token = %v, want backup token 'active-token'", usage.tokens)
	}
	// Live is read once for the liveness check (intentional by design).
	if live.readCount != 1 {
		t.Fatalf("live read count = %d, want exactly 1 (liveness check)", live.readCount)
	}
}

func TestListAccountsMetadataSkipsUsageFetch(t *testing.T) {
	usage := &listTestUsageFetcher{}
	svc := &Service{
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{1},
			Accounts: map[int]*domain.Account{
				1: {Number: 1, Email: "active@example.com"},
			},
		}},
		Usage: usage,
	}

	res, err := svc.ListAccountsMetadata(context.Background())
	if err != nil {
		t.Fatalf("ListAccountsMetadata returned error: %v", err)
	}
	if len(res.Accounts) != 1 || !res.Accounts[0].IsActive {
		t.Fatalf("unexpected metadata view: %+v", res.Accounts)
	}
	if len(usage.tokens) != 0 {
		t.Fatalf("metadata list usage tokens = %v, want none", usage.tokens)
	}
}

func TestListAccountsUsageForFetchesRequestedAccounts(t *testing.T) {
	usage := &listTestUsageFetcher{}
	svc := &Service{
		Backup: &listTestBackupStore{
			blobs: map[int]domain.CredentialBlob{
				1: credentialBlob("one-token", "one-refresh", time.Now().Add(time.Hour)),
				2: credentialBlob("two-token", "two-refresh", time.Now().Add(time.Hour)),
			},
			writes: map[int]domain.CredentialBlob{},
		},
		Registry: listTestRegistryStore{reg: &domain.Registry{
			ActiveAccountNumber: 1,
			Sequence:            []int{1, 2},
			Accounts: map[int]*domain.Account{
				1: {Number: 1, Email: "one@example.com"},
				2: {Number: 2, Email: "two@example.com"},
			},
		}},
		Usage:   usage,
		Refresh: &listTestTokenRefresher{},
	}

	res, err := svc.ListAccountsUsageFor(context.Background(), map[int]bool{2: true})
	if err != nil {
		t.Fatalf("ListAccountsUsageFor returned error: %v", err)
	}
	if res.Accounts[0].Usage != nil || res.Accounts[1].Usage == nil {
		t.Fatalf("usage rows = %+v, want only account 2 filled", res.Accounts)
	}
	if len(usage.tokens) != 1 || usage.tokens[0] != "two-token" {
		t.Fatalf("usage tokens = %v, want only account 2 token", usage.tokens)
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

func TestListAccountsRefreshesExpiredActiveBackupUsesLiveForInspect(t *testing.T) {
	// Live is read for liveness inspection even when the backup is expired and
	// needs refreshing. The backup token is still used for the usage fetch.
	liveBlob := credentialBlob("live-token", "live-refresh", time.Now().Add(time.Hour))
	live := &listTestLiveStore{blob: liveBlob}
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
	// Live IS read now (liveness check) — exactly once.
	if live.readCount != 1 {
		t.Fatalf("live read count = %d, want 1", live.readCount)
	}
	if refresh.calls != 1 {
		t.Fatalf("refresh calls = %d, want 1", refresh.calls)
	}
	if _, ok := backup.writes[1]; !ok {
		t.Fatal("expired active backup was not persisted after refresh")
	}
	// fillUsage fetches with the refreshed backup token; inspectActiveCredential
	// probes with the live token. Both should appear.
	found := false
	for _, tok := range usage.tokens {
		if tok == "fresh-token" {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("usage tokens = %v, want refreshed backup token 'fresh-token' among them", usage.tokens)
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

// listTestUsageFetcherErr returns a fixed error for every Fetch call.
// Used in active-credential liveness tests where we need to simulate 401 / 429.
type listTestUsageFetcherErr struct {
	mu     sync.Mutex
	tokens []string
	err    error
}

func (f *listTestUsageFetcherErr) Fetch(_ context.Context, accessToken string) (*domain.Usage, error) {
	f.mu.Lock()
	f.tokens = append(f.tokens, accessToken)
	f.mu.Unlock()
	return nil, f.err
}

// --- Active credential liveness tests ---

// mkActiveRegistry returns a single-account registry with account #1 active.
func mkActiveRegistry() *domain.Registry {
	return &domain.Registry{
		ActiveAccountNumber: 1,
		Sequence:            []int{1},
		Accounts:            map[int]*domain.Account{1: {Number: 1, Email: "active@example.com"}},
	}
}

// TestInspectActive_EmptyLiveBlob: logged-out state (empty Keychain slot) →
// active account must be flagged needs_login.
func TestInspectActive_EmptyLiveBlob(t *testing.T) {
	live := &listTestLiveStore{blob: ""}
	svc := &Service{
		Live:     live,
		Registry: listTestRegistryStore{reg: mkActiveRegistry()},
		// No Backup/Usage — metadata-only path is fine for this check.
	}

	res, err := svc.ListAccountsMetadata(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	act := res.Accounts[0]
	if act.CredentialState != "needs_login" {
		t.Fatalf("credential state = %q, want needs_login", act.CredentialState)
	}
	if act.CredentialError == "" {
		t.Fatal("credentialError must be non-empty")
	}
}

// TestInspectActive_ValidNonExpiredToken_UsageFetch401: a non-expired token
// that gets a 401 from the usage endpoint → definitively revoked → needs_login.
func TestInspectActive_ValidNonExpiredToken_UsageFetch401(t *testing.T) {
	liveBlob := credentialBlob("live-access", "live-refresh", time.Now().Add(time.Hour))
	live := &listTestLiveStore{blob: liveBlob}
	usage := &listTestUsageFetcherErr{err: &oauth.UnauthorizedError{Body: "token revoked"}}

	svc := &Service{
		Live:     live,
		Usage:    usage,
		Registry: listTestRegistryStore{reg: mkActiveRegistry()},
	}

	res, err := svc.ListAccountsMetadata(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	act := res.Accounts[0]
	if act.CredentialState != "needs_login" {
		t.Fatalf("credential state = %q, want needs_login", act.CredentialState)
	}
	if act.CredentialError == "" {
		t.Fatal("credentialError must be non-empty")
	}
	// Probe must use the LIVE access token, not backup.
	if len(usage.tokens) != 1 || usage.tokens[0] != "live-access" {
		t.Fatalf("usage probe token = %v, want live-access", usage.tokens)
	}
}

// TestInspectActive_ValidNonExpiredToken_UsageFetch429: 429 rate-limit on the
// liveness probe must NOT flag needs_login (conservative — could be transient).
func TestInspectActive_ValidNonExpiredToken_UsageFetch429(t *testing.T) {
	liveBlob := credentialBlob("live-access", "live-refresh", time.Now().Add(time.Hour))
	live := &listTestLiveStore{blob: liveBlob}
	usage := &listTestUsageFetcherErr{err: &oauth.RateLimitedError{RetryAfter: "60"}}

	svc := &Service{
		Live:     live,
		Usage:    usage,
		Registry: listTestRegistryStore{reg: mkActiveRegistry()},
	}

	res, err := svc.ListAccountsMetadata(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	act := res.Accounts[0]
	if act.CredentialState == "needs_login" {
		t.Fatalf("rate-limit must not set needs_login, got %q / %q", act.CredentialState, act.CredentialError)
	}
}

// TestInspectActive_ValidNonExpiredToken_UsageFetchSuccess: successful probe →
// credential is healthy → must NOT set needs_login.
func TestInspectActive_ValidNonExpiredToken_UsageFetchSuccess(t *testing.T) {
	liveBlob := credentialBlob("live-access", "live-refresh", time.Now().Add(time.Hour))
	live := &listTestLiveStore{blob: liveBlob}
	usage := &listTestUsageFetcher{} // always returns success

	svc := &Service{
		Live:     live,
		Usage:    usage,
		Registry: listTestRegistryStore{reg: mkActiveRegistry()},
	}

	res, err := svc.ListAccountsMetadata(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	act := res.Accounts[0]
	// A successful live probe must emit the positive "ready" signal so a stale
	// needs_login cannot stick across snapshot merges on the widget side.
	if act.CredentialState != "ready" {
		t.Fatalf("healthy live token must set ready, got %q / %q", act.CredentialState, act.CredentialError)
	}
}

// TestInspectActive_HealthyLive_DeadBackup: live credential is healthy but the
// backup token is expired/revoked. The original plan's false-positive bug.
// Result must NOT be needs_login.
func TestInspectActive_HealthyLive_DeadBackup(t *testing.T) {
	liveBlob := credentialBlob("live-access", "live-refresh", time.Now().Add(time.Hour))
	live := &listTestLiveStore{blob: liveBlob}

	backup := &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			// Expired backup whose refresh is revoked.
			1: credentialBlob("stale-backup", "dead-refresh", time.Now().Add(-time.Hour)),
		},
		writes: map[int]domain.CredentialBlob{},
	}
	// Backup refresh fails with a generic error (not invalid_grant — irrelevant
	// here since active fillUsage does not flag needs_login for active accounts).
	backupRefresher := &listTestTokenRefresher{err: errors.New("oauth refresh 400: invalid_grant")}

	// Usage succeeds for the live-access probe.
	usage := &listTestUsageFetcher{}

	svc := &Service{
		Live:     live,
		Backup:   backup,
		Usage:    usage,
		Refresh:  backupRefresher,
		Registry: listTestRegistryStore{reg: mkActiveRegistry()},
	}

	res, err := svc.ListAccounts(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	act := res.Accounts[0]
	if act.CredentialState == "needs_login" {
		t.Fatalf("healthy live + dead backup must NOT set needs_login; got %q / %q", act.CredentialState, act.CredentialError)
	}
}

// TestInspectActive_InactiveAccountUnchanged: inactive accounts continue to
// use the backup-token path and are unaffected by inspectActiveCredential.
func TestInspectActive_InactiveAccountUnchanged(t *testing.T) {
	liveBlob := credentialBlob("live-access", "live-refresh", time.Now().Add(time.Hour))
	live := &listTestLiveStore{blob: liveBlob}

	backup := &listTestBackupStore{
		blobs: map[int]domain.CredentialBlob{
			1: credentialBlob("active-backup", "active-refresh", time.Now().Add(time.Hour)),
			// Inactive account #2 has no backup → should get needs_login from fillUsage.
		},
		writes: map[int]domain.CredentialBlob{},
	}
	usage := &listTestUsageFetcher{}

	reg := &domain.Registry{
		ActiveAccountNumber: 1,
		Sequence:            []int{1, 2},
		Accounts: map[int]*domain.Account{
			1: {Number: 1, Email: "active@example.com"},
			2: {Number: 2, Email: "inactive@example.com"},
		},
	}

	svc := &Service{
		Live:     live,
		Backup:   backup,
		Usage:    usage,
		Refresh:  &listTestTokenRefresher{},
		Registry: listTestRegistryStore{reg: reg},
	}

	res, err := svc.ListAccounts(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var inactive *AccountView
	for _, a := range res.Accounts {
		if !a.IsActive {
			inactive = a
		}
	}
	if inactive == nil {
		t.Fatal("did not find inactive account in result")
	}
	// Inactive with missing backup → needs_login via fillUsage (backup path).
	if inactive.CredentialState != "needs_login" {
		t.Fatalf("inactive missing backup: credential state = %q, want needs_login", inactive.CredentialState)
	}
}

func credentialBlob(accessToken, refreshToken string, expiresAt time.Time) domain.CredentialBlob {
	return domain.CredentialBlob(`{"claudeAiOauth":{"accessToken":"` + accessToken + `","refreshToken":"` + refreshToken + `","expiresAt":` + expiresMillis(expiresAt) + `}}`)
}

func expiresMillis(t time.Time) string {
	return strconv.FormatInt(t.UnixMilli(), 10)
}
