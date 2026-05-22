// Package port defines interfaces (hexagonal ports) the use-cases depend on.
// All I/O lives behind these — adapters implement them.
package port

import (
	"context"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// LiveCredentialStore is the active credential slot Claude Code reads.
// macOS: Keychain entry "Claude Code-credentials". Linux: ~/.claude/.credentials.json.
type LiveCredentialStore interface {
	Read(ctx context.Context) (domain.CredentialBlob, error)
	Write(ctx context.Context, blob domain.CredentialBlob) error
}

// BackupCredentialStore holds inactive accounts' credentials, keyed by number+email.
type BackupCredentialStore interface {
	Read(ctx context.Context, accountNum int, email string) (domain.CredentialBlob, error)
	Write(ctx context.Context, accountNum int, email string, blob domain.CredentialBlob) error
	Delete(ctx context.Context, accountNum int, email string) error
}

// ClaudeConfigStore is ~/.claude.json.
type ClaudeConfigStore interface {
	Read(ctx context.Context) (*domain.ClaudeConfig, error)
	Write(ctx context.Context, cfg *domain.ClaudeConfig) error
	Exists() bool
}

// RegistryStore persists the Registry (which accounts exist, who's active).
type RegistryStore interface {
	Load(ctx context.Context) (*domain.Registry, error)
	Save(ctx context.Context, r *domain.Registry) error
}

// UsageFetcher calls the Anthropic OAuth usage API.
type UsageFetcher interface {
	Fetch(ctx context.Context, accessToken string) (*domain.Usage, error)
}

// TokenRefresher exchanges a refresh token for a new access token.
type TokenRefresher interface {
	Refresh(ctx context.Context, refreshToken string) (*domain.OAuthPayload, error)
}

// UsageLogScanner aggregates Claude Code token usage from local JSONL session
// logs (~/.claude/projects/**/*.jsonl). Adapter decides scanning strategy
// (mtime cutoff, line-by-line parse) — usecase only sees the final report.
//
// Rates are passed in per-scan so the cost column reflects whatever pricing
// snapshot is currently active (the hosted JSON fetched by PricingProvider,
// or the bundled fallback on a cold network).
type UsageLogScanner interface {
	Scan(ctx context.Context, now time.Time, rates []domain.ModelPricing) (*domain.UsageStatsReport, error)
}

// PricingProvider is the runtime source for Anthropic's per-model rate table.
// On launch it bootstraps from the bundled domain.PublishedPricing(), then
// refreshes from a hosted JSON in the background so existing builds pick up
// new Anthropic prices without a new release. Current() never blocks: it
// returns whatever snapshot is in memory right now.
type PricingProvider interface {
	// Current returns the active rates plus a human-readable reference
	// (e.g. "anthropic.com/pricing, snapshot 2026-09").
	Current() ([]domain.ModelPricing, string)
	// Refresh kicks off a background HTTP fetch. No-op if a refresh ran
	// within the provider's TTL. Safe to call from any goroutine.
	Refresh(ctx context.Context)
}

// SessionInspector reads ~/.claude/sessions/*.json and reports liveness.
type SessionInspector interface {
	List(ctx context.Context) ([]domain.ClaudeSession, error)
	Report(ctx context.Context) (*domain.SessionReport, error)
}

// FileLock serialises swap operations across processes.
type FileLock interface {
	Acquire(ctx context.Context) error
	Release() error
}

// MCPSecretStore holds per-account connector tokens in the macOS Keychain.
// Keys are (accountNumber, service). Payload is provider-defined opaque JSON.
type MCPSecretStore interface {
	Read(ctx context.Context, accountNum int, service domain.MCPService) (string, error)
	Write(ctx context.Context, accountNum int, service domain.MCPService, payload string) error
	Delete(ctx context.Context, accountNum int, service domain.MCPService) error
	DeleteAll(ctx context.Context, accountNum int) error
}
