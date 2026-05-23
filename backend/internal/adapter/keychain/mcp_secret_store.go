package keychain

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// mcpServiceFormat is "claude-bar-mcp:<account-key>:<service>".
// account-key is the account number (not email) or "shared" for the local
// machine-wide fallback connector. service is the canonical MCPService
// identifier ("slack", "clickup", "gdrive").
const mcpServiceFormat = "claude-bar-mcp:%s:%s"

// migrationSentinelService marks that MCP secrets have been canonicalised
// under the "shared" account-key. Presence skips re-running migration.
const migrationSentinelService = "claude-bar-mcp:shared:.migrated-v1"

// MCPSecretStore stores provider tokens in the macOS Keychain.
type MCPSecretStore struct {
	user string
}

// NewMCPSecretStore binds to the current $USER.
func NewMCPSecretStore() *MCPSecretStore {
	user := os.Getenv("USER")
	if user == "" {
		user = "user"
	}
	return &MCPSecretStore{user: user}
}

func (s *MCPSecretStore) kc(accountNum int, service domain.MCPService) *Keychain {
	accountKey := fmt.Sprintf("%d", accountNum)
	if accountNum == 0 {
		accountKey = "shared"
	}
	return New(fmt.Sprintf(mcpServiceFormat, accountKey, service), s.user)
}

// Read returns the stored payload. Returns ("", nil) when no entry exists so
// callers can treat "missing" without leaking Keychain CLI errors.
func (s *MCPSecretStore) Read(ctx context.Context, accountNum int, service domain.MCPService) (string, error) {
	out, err := s.kc(accountNum, service).Read(ctx)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return "", nil
		}
		return "", err
	}
	return out, nil
}

// Write upserts the payload.
func (s *MCPSecretStore) Write(ctx context.Context, accountNum int, service domain.MCPService, payload string) error {
	return s.kc(accountNum, service).Write(ctx, payload)
}

// Delete removes one connector's secret. No error if absent.
func (s *MCPSecretStore) Delete(ctx context.Context, accountNum int, service domain.MCPService) error {
	return s.kc(accountNum, service).Delete(ctx)
}

// DeleteAll removes every connector secret for an account. Non-atomic on
// purpose: a Keychain race on one service must not leave secrets behind on
// the others, so errors are collected and continued past — the cascade-delete
// contract (threat model §11) requires every secret to be attempted.
func (s *MCPSecretStore) DeleteAll(ctx context.Context, accountNum int) error {
	var msgs []string
	for _, svc := range domain.AllMCPServices {
		if err := s.kc(accountNum, svc).Delete(ctx); err != nil {
			msgs = append(msgs, fmt.Sprintf("%s: %v", svc, err))
		}
	}
	if len(msgs) > 0 {
		return errors.New("delete mcp secrets: " + strings.Join(msgs, "; "))
	}
	return nil
}

// GetShared reads the canonical machine-wide token for a service. Convenience
// wrapper around Read(ctx, 0, service) used by Command Center MCP tools.
func (s *MCPSecretStore) GetShared(ctx context.Context, service domain.MCPService) (string, error) {
	return s.Read(ctx, 0, service)
}

// PutShared upserts the canonical machine-wide token for a service.
func (s *MCPSecretStore) PutShared(ctx context.Context, service domain.MCPService, payload string) error {
	return s.Write(ctx, 0, service, payload)
}

// IsMigratedToShared reports whether the one-shot MCP-to-shared canonicalisation
// has already run on this machine. Presence of the sentinel keychain entry is
// the source of truth — never re-derive from secret presence (a user with no
// connectors yet looks identical to an un-migrated state).
func (s *MCPSecretStore) IsMigratedToShared(ctx context.Context) (bool, error) {
	payload, err := New(migrationSentinelService, s.user).Read(ctx)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return false, nil
		}
		return false, err
	}
	return payload != "", nil
}

// MarkMigratedToShared writes the migration sentinel. Payload is the RFC3339
// timestamp so a future Diagnostics surface can show when migration ran.
func (s *MCPSecretStore) MarkMigratedToShared(ctx context.Context, ts time.Time) error {
	return New(migrationSentinelService, s.user).Write(ctx, ts.UTC().Format(time.RFC3339))
}
