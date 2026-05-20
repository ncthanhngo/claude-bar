package mcp

import (
	"context"
	"errors"
	"fmt"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// ErrNoActiveAccount means no Claude Bar account is currently active.
var ErrNoActiveAccount = errors.New("no active Claude Bar account")

// ErrConnectorDisabled means the active account has the connector turned off.
var ErrConnectorDisabled = errors.New("connector disabled")

// ErrConnectorUnauthorized means the active account has no Keychain secret
// for this connector. The caller MUST NOT leak which other accounts do.
var ErrConnectorUnauthorized = errors.New("connector not authorized")

// CallContext is the per-tool-call snapshot the gateway hands to handlers.
// It is rebuilt on every tools/call so a mid-session account switch picks up
// the new active profile without restarting Claude Code.
type CallContext struct {
	AccountNumber int
	Service       domain.MCPService
	Payload       string
	Meta          *domain.MCPConnector
}

// Resolver looks up the active account and connector profile for one call.
type Resolver struct {
	Registry port.RegistryStore
	Secrets  port.MCPSecretStore
}

// Resolve returns a CallContext or one of the typed errors above. It reads
// registry.json every call — cheap relative to the remote API hop.
func (r *Resolver) Resolve(ctx context.Context, svc domain.MCPService) (*CallContext, error) {
	reg, err := r.Registry.Load(ctx)
	if err != nil {
		return nil, fmt.Errorf("load registry: %w", err)
	}
	if reg.ActiveAccountNumber == 0 {
		return nil, ErrNoActiveAccount
	}
	acc, ok := reg.Accounts[reg.ActiveAccountNumber]
	if !ok {
		return nil, ErrNoActiveAccount
	}
	meta, ok := acc.MCPConnectors[svc]
	if !ok || meta == nil || !meta.Enabled {
		return nil, ErrConnectorDisabled
	}
	payload, err := r.Secrets.Read(ctx, acc.Number, svc)
	if err != nil {
		return nil, fmt.Errorf("read secret: %w", err)
	}
	if payload == "" {
		return nil, ErrConnectorUnauthorized
	}
	return &CallContext{
		AccountNumber: acc.Number,
		Service:       svc,
		Payload:       payload,
		Meta:          meta,
	}, nil
}
