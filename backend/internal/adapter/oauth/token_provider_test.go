package oauth

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// --- Fakes ---

type fakeLive struct {
	blob    domain.CredentialBlob
	writes  int
	written domain.CredentialBlob
	readErr error
}

func (f *fakeLive) Read(ctx context.Context) (domain.CredentialBlob, error) {
	if f.readErr != nil {
		return "", f.readErr
	}
	return f.blob, nil
}

func (f *fakeLive) Write(ctx context.Context, b domain.CredentialBlob) error {
	f.writes++
	f.written = b
	f.blob = b
	return nil
}

type fakeRefresher struct {
	calls   int
	out     *domain.OAuthPayload
	outErr  error
	lastTok string
}

func (f *fakeRefresher) Refresh(ctx context.Context, refreshToken string) (*domain.OAuthPayload, error) {
	f.calls++
	f.lastTok = refreshToken
	if f.outErr != nil {
		return nil, f.outErr
	}
	return f.out, nil
}

type fakeCfg struct {
	uuid string
}

func (f *fakeCfg) Read(ctx context.Context) (*domain.ClaudeConfig, error) {
	return &domain.ClaudeConfig{OAuthAccount: &domain.OAuthAccount{
		EmailAddress: "alice@example.com",
		AccountUUID:  f.uuid,
	}}, nil
}
func (f *fakeCfg) Write(ctx context.Context, c *domain.ClaudeConfig) error { return nil }
func (f *fakeCfg) Exists() bool                                            { return true }

type fakeRegistry struct {
	reg *domain.Registry
}

func (f *fakeRegistry) Load(ctx context.Context) (*domain.Registry, error)  { return f.reg, nil }
func (f *fakeRegistry) Save(ctx context.Context, r *domain.Registry) error  { f.reg = r; return nil }

func buildBlob(t *testing.T, p domain.OAuthPayload) domain.CredentialBlob {
	t.Helper()
	// Compose via WithRefreshed on an empty wrapper.
	empty := domain.CredentialBlob(`{"claudeAiOauth":{}}`)
	b, err := empty.WithRefreshed(&p)
	if err != nil {
		t.Fatalf("buildBlob: %v", err)
	}
	return b
}

func buildRegistry(activeNum int) *domain.Registry {
	r := domain.NewRegistry()
	r.ActiveAccountNumber = activeNum
	r.Accounts[activeNum] = &domain.Account{Number: activeNum, Email: "alice@example.com", OrganizationUUID: "org-1"}
	return r
}

// --- Tests ---

func TestGetFresh_NotActive(t *testing.T) {
	tp := NewTokenProvider(&fakeLive{}, &fakeRefresher{}, &fakeCfg{}, &fakeRegistry{reg: buildRegistry(1)})
	_, _, err := tp.GetFresh(context.Background(), 2)
	if !errors.Is(err, domain.ErrNotActive) {
		t.Fatalf("err = %v, want ErrNotActive", err)
	}
}

func TestGetFresh_LiveStillValid(t *testing.T) {
	future := time.Now().Add(1 * time.Hour).UnixMilli()
	live := &fakeLive{blob: buildBlob(t, domain.OAuthPayload{
		AccessToken: "tok-A", RefreshToken: "ref-A", ExpiresAt: future,
	})}
	ref := &fakeRefresher{}
	tp := NewTokenProvider(live, ref, &fakeCfg{uuid: "acc-uuid-1"}, &fakeRegistry{reg: buildRegistry(1)})

	tok, uuid, err := tp.GetFresh(context.Background(), 1)
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if tok != "tok-A" {
		t.Errorf("token = %q", tok)
	}
	if uuid != "acc-uuid-1" {
		t.Errorf("uuid = %q", uuid)
	}
	if ref.calls != 0 {
		t.Errorf("refresher called %d times — expected 0 when token is fresh", ref.calls)
	}
	if live.writes != 0 {
		t.Errorf("live.Write calls = %d, want 0", live.writes)
	}
}

func TestGetFresh_RefreshOnExpired(t *testing.T) {
	past := time.Now().Add(-1 * time.Hour).UnixMilli()
	live := &fakeLive{blob: buildBlob(t, domain.OAuthPayload{
		AccessToken: "tok-old", RefreshToken: "ref-old", ExpiresAt: past,
	})}
	ref := &fakeRefresher{out: &domain.OAuthPayload{
		AccessToken: "tok-new", RefreshToken: "ref-new",
		ExpiresAt: time.Now().Add(1 * time.Hour).UnixMilli(),
	}}
	tp := NewTokenProvider(live, ref, &fakeCfg{uuid: "acc-uuid-1"}, &fakeRegistry{reg: buildRegistry(1)})

	tok, _, err := tp.GetFresh(context.Background(), 1)
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if tok != "tok-new" {
		t.Errorf("token = %q, want tok-new", tok)
	}
	if ref.calls != 1 {
		t.Errorf("refresher.calls = %d, want 1", ref.calls)
	}
	if ref.lastTok != "ref-old" {
		t.Errorf("refresher saw refresh_token = %q, want ref-old", ref.lastTok)
	}
	if live.writes != 1 {
		t.Errorf("live.Write calls = %d, want 1", live.writes)
	}
	// Verify the rewritten blob carries the new access token.
	p, err := live.written.Extract()
	if err != nil || p.AccessToken != "tok-new" {
		t.Errorf("written blob.access_token = %q (err=%v), want tok-new", p.AccessToken, err)
	}
}

func TestGetFresh_RefreshInvalidGrant(t *testing.T) {
	past := time.Now().Add(-1 * time.Hour).UnixMilli()
	live := &fakeLive{blob: buildBlob(t, domain.OAuthPayload{
		AccessToken: "tok-old", RefreshToken: "ref-old", ExpiresAt: past,
	})}
	ref := &fakeRefresher{outErr: errors.New("oauth refresh 400: invalid_grant")}
	tp := NewTokenProvider(live, ref, &fakeCfg{}, &fakeRegistry{reg: buildRegistry(1)})

	_, _, err := tp.GetFresh(context.Background(), 1)
	if !errors.Is(err, domain.ErrTokenRefreshFailed) {
		t.Fatalf("err = %v, want wrap of ErrTokenRefreshFailed", err)
	}
	if live.writes != 0 {
		t.Errorf("live.Write called on failed refresh — should not happen")
	}
}

func TestGetFresh_AccountUUIDFallback(t *testing.T) {
	future := time.Now().Add(1 * time.Hour).UnixMilli()
	live := &fakeLive{blob: buildBlob(t, domain.OAuthPayload{
		AccessToken: "tok", RefreshToken: "ref", ExpiresAt: future,
	})}
	// Empty AccountUUID in claude.json → provider falls back to registry IdentityKey.
	tp := NewTokenProvider(live, &fakeRefresher{}, &fakeCfg{uuid: ""}, &fakeRegistry{reg: buildRegistry(1)})

	_, uuid, err := tp.GetFresh(context.Background(), 1)
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if uuid != "alice@example.com|org-1" {
		t.Errorf("uuid fallback = %q", uuid)
	}
}
