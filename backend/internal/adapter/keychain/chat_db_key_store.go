package keychain

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// chatDBKeyService is the macOS Keychain service for per-account chat DB
// master keys. Account field carries the AccountUUID. We hex-encode the raw
// 32-byte key for storage so the keychain payload stays printable ASCII —
// /usr/bin/security treats the -w argument as text.
const chatDBKeyService = "dev.ncthanhngo.claude-bar.chat-db-key"

// ChatDBKeyStore implements port.ChatDBKeyStore against the macOS Keychain
// via /usr/bin/security. Keys are stored hex-encoded; Read returns the raw
// 32 bytes after decoding.
type ChatDBKeyStore struct{}

// NewChatDBKeyStore returns a key store; no internal state.
func NewChatDBKeyStore() *ChatDBKeyStore { return &ChatDBKeyStore{} }

// Read fetches and hex-decodes the master key for accountUUID.
// Returns port.ErrKeyNotFound when no entry exists (caller mints + writes
// a fresh one via crypto/rand).
func (s *ChatDBKeyStore) Read(ctx context.Context, accountUUID string) ([]byte, error) {
	if accountUUID == "" {
		return nil, fmt.Errorf("chat db key: empty accountUUID")
	}
	kc := New(chatDBKeyService, accountUUID)
	raw, err := kc.Read(ctx)
	if errors.Is(err, ErrNotFound) {
		return nil, port.ErrKeyNotFound
	}
	if err != nil {
		return nil, err
	}
	key, err := hex.DecodeString(raw)
	if err != nil {
		return nil, fmt.Errorf("decode chat db key: %w", err)
	}
	return key, nil
}

// Write hex-encodes and upserts the master key into the Keychain. Overwrites
// any existing entry — caller is responsible for the consequences (a write
// effectively rotates the key, after which the existing DB becomes unreadable).
func (s *ChatDBKeyStore) Write(ctx context.Context, accountUUID string, key []byte) error {
	if accountUUID == "" {
		return fmt.Errorf("chat db key: empty accountUUID")
	}
	if len(key) == 0 {
		return fmt.Errorf("chat db key: empty key")
	}
	kc := New(chatDBKeyService, accountUUID)
	return kc.Write(ctx, hex.EncodeToString(key))
}

// Delete removes the master key. Called when an account is removed from the
// widget — combined with deleting the SQLCipher DB file, the on-disk data
// becomes unrecoverable. No-op when the entry doesn't exist.
func (s *ChatDBKeyStore) Delete(ctx context.Context, accountUUID string) error {
	if accountUUID == "" {
		return fmt.Errorf("chat db key: empty accountUUID")
	}
	kc := New(chatDBKeyService, accountUUID)
	return kc.Delete(ctx)
}

// Compile-time guard.
var _ port.ChatDBKeyStore = (*ChatDBKeyStore)(nil)
