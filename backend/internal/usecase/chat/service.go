// Package chat exposes the chat-with-Claude business operations the csw
// CLI and the MCP gateway invoke. Pure orchestration over four ports:
// OAuthTokenProvider, ChatClient, ChatStorage (per-account, opened lazily
// by the OpenStorage factory), and a clock. All I/O lives behind the
// ports so the unit tests run with in-memory fakes.
package chat

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// OpenStorageFunc opens or creates a per-account storage handle. Returning
// the concrete *chatstorage.Storage type would create an import cycle the
// other way; we type the result as port.ChatStorage and a second optional
// shape (VaultStorage) below.
type OpenStorageFunc func(ctx context.Context, accountUUID string) (port.ChatStorage, error)

// VaultStorage is satisfied by *chatstorage.Storage and lets the chat
// usecase reach the AEAD vault without depending on the concrete type.
// Implementations are responsible for AAD-binding to (accountUUID, id).
type VaultStorage interface {
	port.ChatStorage
	// VaultWrite encrypts plaintext and stores it on disk; returns
	// (filePath, nonceHex, error) for the caller to persist on the
	// matching attachment row.
	VaultWrite(ctx context.Context, attachmentID string, plaintext []byte) (string, string, error)
	// VaultRead decrypts and returns the plaintext for the attachment.
	VaultRead(ctx context.Context, attachmentID, filePath, nonceHex string) ([]byte, error)
}

// Service is the chat-mode entry point used by the CLI / MCP layers.
type Service struct {
	TokenProvider port.OAuthTokenProvider
	ChatClient    port.ChatClient
	OpenStorage   OpenStorageFunc
	Now           func() time.Time
	NewID         func() string
}

// NewService wires production defaults for Now / NewID; production caller
// in cmd/csw supplies the three ports.
func NewService(
	tokenProvider port.OAuthTokenProvider,
	chatClient port.ChatClient,
	openStorage OpenStorageFunc,
) *Service {
	return &Service{
		TokenProvider: tokenProvider,
		ChatClient:    chatClient,
		OpenStorage:   openStorage,
		Now:           func() time.Time { return time.Now().UTC() },
		NewID:         randomID,
	}
}

// randomID returns a 16-byte (128-bit) hex string. We don't depend on a
// UUID library — chat IDs are opaque to callers and a uniform random hex
// string is plenty for collision resistance within a per-account DB.
func randomID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// openForAccount fetches a fresh OAuth token + accountUUID, then opens the
// per-account storage. Every chat operation starts with this call so the
// account binding is validated once at the top.
func (s *Service) openForAccount(ctx context.Context, accountNum int) (string, string, port.ChatStorage, error) {
	accessToken, accountUUID, err := s.TokenProvider.GetFresh(ctx, accountNum)
	if err != nil {
		return "", "", nil, err
	}
	storage, err := s.OpenStorage(ctx, accountUUID)
	if err != nil {
		return "", "", nil, err
	}
	return accessToken, accountUUID, storage, nil
}
