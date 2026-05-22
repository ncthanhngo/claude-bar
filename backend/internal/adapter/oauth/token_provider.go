package oauth

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// TokenProvider wraps the live credential store + refresher to give the chat
// usecase a single "always-fresh token" call. MVP: chat only runs on the
// active account so we read exclusively from LiveCredentialStore — backup
// store integration is reserved for a future per-account chat mode.
//
// `refreshMu` serialises the read-refresh-write sequence so two concurrent
// GetFresh calls on an expired blob can't both trigger a refresh. Anthropic
// rotates refresh_token on every successful refresh; a double-refresh would
// fail the second one with invalid_grant and surface a spurious re-login
// prompt to the user. The chat MCP transport and widget caller both run on
// the main thread today, but the lock is cheap insurance for the future.
type TokenProvider struct {
	live      port.LiveCredentialStore
	refresher port.TokenRefresher
	cfg       port.ClaudeConfigStore
	registry  port.RegistryStore

	refreshMu sync.Mutex
}

// NewTokenProvider wires the four collaborators. Adapter package owns the
// concrete imports; usecase consumes only the port.
func NewTokenProvider(
	live port.LiveCredentialStore,
	refresher port.TokenRefresher,
	cfg port.ClaudeConfigStore,
	registry port.RegistryStore,
) *TokenProvider {
	return &TokenProvider{live: live, refresher: refresher, cfg: cfg, registry: registry}
}

// GetFresh returns a non-expired access token + AccountUUID for accountNum.
// Behaviour:
//   - Returns domain.ErrNotActive if accountNum is not the currently-active one.
//   - Refreshes lazily if the live blob is at / near expiry; writes the
//     rotated blob back into the live store so the next caller is fast.
//   - Returns domain.ErrTokenRefreshFailed on a non-transient refresh failure
//     (invalid_grant / 400). Transient errors (timeout, 5xx) are wrapped raw.
func (p *TokenProvider) GetFresh(ctx context.Context, accountNum int) (string, string, error) {
	reg, err := p.registry.Load(ctx)
	if err != nil {
		return "", "", fmt.Errorf("registry load: %w", err)
	}
	if accountNum != reg.ActiveAccountNumber {
		return "", "", domain.ErrNotActive
	}

	blob, err := p.live.Read(ctx)
	if err != nil {
		return "", "", fmt.Errorf("live credential read: %w", err)
	}
	payload, err := blob.Extract()
	if err != nil {
		return "", "", fmt.Errorf("extract oauth payload: %w", err)
	}

	if IsExpired(payload.ExpiresAt) {
		p.refreshMu.Lock()
		defer p.refreshMu.Unlock()
		// Re-read under the lock: a concurrent caller may have refreshed
		// already, in which case our work is done.
		blob, err = p.live.Read(ctx)
		if err != nil {
			return "", "", fmt.Errorf("live credential re-read: %w", err)
		}
		if payload2, err2 := blob.Extract(); err2 == nil && !IsExpired(payload2.ExpiresAt) {
			payload = payload2
		} else {
			fresh, err := p.refresher.Refresh(ctx, payload.RefreshToken)
			if err != nil {
				return "", "", classifyRefreshError(err)
			}
			updated, err := blob.WithRefreshed(fresh)
			if err != nil {
				return "", "", fmt.Errorf("merge refreshed blob: %w", err)
			}
			if err := p.live.Write(ctx, updated); err != nil {
				return "", "", fmt.Errorf("live credential write: %w", err)
			}
			payload = fresh
		}
	}

	accountUUID := p.accountUUID(ctx, reg, accountNum)
	return payload.AccessToken, accountUUID, nil
}

// accountUUID returns the canonical UUID for accountNum, preferring the
// fresh value from ~/.claude.json (Claude Code writes it on every login)
// and falling back to the registry's organization UUID + email composite.
// Empty string when the system has never logged in — callers should treat
// this as a per-account opt-out from chat.
func (p *TokenProvider) accountUUID(ctx context.Context, reg *domain.Registry, accountNum int) string {
	if cfg, err := p.cfg.Read(ctx); err == nil && cfg != nil && cfg.OAuthAccount != nil {
		if u := cfg.OAuthAccount.AccountUUID; u != "" {
			return u
		}
	}
	if acc := reg.Accounts[accountNum]; acc != nil {
		// IdentityKey is stable per (email, orgUUID) — close enough for chat
		// scoping until ~/.claude.json carries the UUID.
		return acc.IdentityKey()
	}
	return ""
}

// classifyRefreshError maps OAuth refresh failures to chat domain sentinels.
// Anthropic returns 400 with "invalid_grant" for revoked tokens — those need
// the user to re-login. Network / 5xx pass through as-is for the usecase
// to consider a transient retry.
func classifyRefreshError(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return err
	}
	msg := err.Error()
	for _, marker := range []string{
		"invalid_grant", "invalid_token",
		"oauth refresh 400", "oauth refresh 401",
	} {
		if strings.Contains(msg, marker) {
			return fmt.Errorf("%w: %v", domain.ErrTokenRefreshFailed, err)
		}
	}
	return fmt.Errorf("token refresh: %w", err)
}

// Compile-time guard.
var _ port.OAuthTokenProvider = (*TokenProvider)(nil)
