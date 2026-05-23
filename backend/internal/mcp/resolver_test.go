package mcp

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

type fakeRegistry struct{ reg *domain.Registry }

func (f *fakeRegistry) Load(_ context.Context) (*domain.Registry, error) { return f.reg, nil }
func (f *fakeRegistry) Save(_ context.Context, r *domain.Registry) error { f.reg = r; return nil }

type fakeSecrets map[string]string

func key(n int, s domain.MCPService) string { return string(rune(n+'0')) + ":" + string(s) }

func (f fakeSecrets) Read(_ context.Context, n int, s domain.MCPService) (string, error) {
	return f[key(n, s)], nil
}
func (f fakeSecrets) Write(_ context.Context, n int, s domain.MCPService, p string) error {
	f[key(n, s)] = p
	return nil
}
func (f fakeSecrets) Delete(_ context.Context, n int, s domain.MCPService) error {
	delete(f, key(n, s))
	return nil
}
func (f fakeSecrets) DeleteAll(_ context.Context, n int) error {
	for _, s := range domain.AllMCPServices {
		delete(f, key(n, s))
	}
	return nil
}
func (f fakeSecrets) IsMigratedToShared(_ context.Context) (bool, error)  { return false, nil }
func (f fakeSecrets) MarkMigratedToShared(_ context.Context, _ time.Time) error { return nil }

func newResolverFixture(active int, enabled bool, hasSecret bool) *Resolver {
	reg := domain.NewRegistry()
	reg.ActiveAccountNumber = active
	if active > 0 {
		acc := &domain.Account{Number: active, Email: "a@b.c", CreatedAt: time.Now()}
		if enabled {
			acc.MCPConnectors = domain.AccountConnectors{
				domain.MCPServiceSlack: &domain.MCPConnector{Enabled: true},
			}
		}
		reg.Accounts[active] = acc
		reg.Sequence = []int{active}
	}
	secrets := fakeSecrets{}
	if hasSecret {
		secrets[key(active, domain.MCPServiceSlack)] = "xoxp-fake"
	}
	return &Resolver{Registry: &fakeRegistry{reg: reg}, Secrets: secrets}
}

func TestResolveNoActiveAccount(t *testing.T) {
	r := newResolverFixture(0, false, false)
	_, err := r.Resolve(context.Background(), domain.MCPServiceSlack)
	if !errors.Is(err, ErrNoActiveAccount) {
		t.Fatalf("want ErrNoActiveAccount, got %v", err)
	}
}

func TestResolveConnectorDisabled(t *testing.T) {
	r := newResolverFixture(1, false, true)
	_, err := r.Resolve(context.Background(), domain.MCPServiceSlack)
	if !errors.Is(err, ErrConnectorDisabled) {
		t.Fatalf("want ErrConnectorDisabled, got %v", err)
	}
}

func TestResolveConnectorUnauthorized(t *testing.T) {
	r := newResolverFixture(1, true, false)
	_, err := r.Resolve(context.Background(), domain.MCPServiceSlack)
	if !errors.Is(err, ErrConnectorUnauthorized) {
		t.Fatalf("want ErrConnectorUnauthorized, got %v", err)
	}
}

func TestResolveSuccess(t *testing.T) {
	r := newResolverFixture(1, true, true)
	cc, err := r.Resolve(context.Background(), domain.MCPServiceSlack)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cc.AccountNumber != 1 || cc.Payload != "xoxp-fake" {
		t.Fatalf("bad CallContext: %+v", cc)
	}
}

func TestResolveFallsBackToSharedConnector(t *testing.T) {
	r := newResolverFixture(1, false, false)
	reg := r.Registry.(*fakeRegistry).reg
	reg.SharedMCPConnectors = domain.AccountConnectors{
		domain.MCPServiceSlack: &domain.MCPConnector{Enabled: true},
	}
	r.Secrets.(fakeSecrets)[key(0, domain.MCPServiceSlack)] = "xoxp-shared"

	cc, err := r.Resolve(context.Background(), domain.MCPServiceSlack)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cc.AccountNumber != 0 || cc.Payload != "xoxp-shared" {
		t.Fatalf("bad shared CallContext: %+v", cc)
	}
}

func TestResolvePrefersAccountConnectorOverShared(t *testing.T) {
	r := newResolverFixture(1, true, true)
	reg := r.Registry.(*fakeRegistry).reg
	reg.SharedMCPConnectors = domain.AccountConnectors{
		domain.MCPServiceSlack: &domain.MCPConnector{Enabled: true},
	}
	r.Secrets.(fakeSecrets)[key(0, domain.MCPServiceSlack)] = "xoxp-shared"

	cc, err := r.Resolve(context.Background(), domain.MCPServiceSlack)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cc.AccountNumber != 1 || cc.Payload != "xoxp-fake" {
		t.Fatalf("account connector should win: %+v", cc)
	}
}
