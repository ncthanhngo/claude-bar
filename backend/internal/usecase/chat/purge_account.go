package chat

import (
	"context"
	"fmt"
	"os"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// PurgeAccount removes all chat data for accountUUID: deletes the on-disk
// chat dir (DB + WAL + SHM + every .enc attachment), then removes the
// master key from the Keychain. Used by the account-removal flow so a
// re-added account doesn't inherit ghost chat history.
//
// Safe to call when no chat data exists (idempotent — file/keychain misses
// are not errors). NOT scoped through the storage interface because we
// want to wipe even when the DB is corrupt or the key has rotated.
type PurgeOptions struct {
	// KeyStore is the macOS Keychain ChatDBKeyStore; injected so tests can
	// fake it. Required.
	KeyStore port.ChatDBKeyStore
}

// PurgeAccount deletes everything chat-related for accountUUID.
// Order:
//  1. RemoveAll the per-account dir (DB + attachments + WAL files).
//  2. Delete the master key entry in the Keychain.
//
// We do the file remove first so that a Keychain delete failure leaves no
// data orphaned without its key — better to risk a leftover key entry than
// a directory of unreadable encrypted bytes.
func PurgeAccount(ctx context.Context, accountUUID string, opts PurgeOptions) error {
	if accountUUID == "" {
		return fmt.Errorf("chat.PurgeAccount: empty accountUUID")
	}
	if opts.KeyStore == nil {
		return fmt.Errorf("chat.PurgeAccount: missing key store")
	}

	dir := adapter.ChatAccountDir(accountUUID)
	if err := os.RemoveAll(dir); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove chat dir %s: %w", dir, err)
	}

	if err := opts.KeyStore.Delete(ctx, accountUUID); err != nil {
		// Keychain "not found" is fine — we may have purged before any
		// chat ever ran for this account. Don't mask other errors though.
		return fmt.Errorf("delete chat db key: %w", err)
	}
	return nil
}
