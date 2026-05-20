package keychain

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// mcpServiceFormat is "claude-bar-mcp:<account-number>:<service>".
// account-number (not email) survives rename. service is the canonical
// MCPService identifier ("slack", "clickup", "gdrive").
const mcpServiceFormat = "claude-bar-mcp:%d:%s"

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
	return New(fmt.Sprintf(mcpServiceFormat, accountNum, service), s.user)
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
