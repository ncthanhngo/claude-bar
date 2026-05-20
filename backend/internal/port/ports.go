// Package port defines interfaces (hexagonal ports) the use-cases depend on.
// All I/O lives behind these — adapters implement them.
package port

import (
	"context"

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
