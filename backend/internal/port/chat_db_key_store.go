package port

import "context"

// ChatDBKeyStore reads / writes the 256-bit symmetric key used to open the
// per-account SQLCipher chat database. macOS impl stores the key in the
// Keychain under "claude-bar-chat:<accountUUID>"; deletion happens when the
// account is removed from the widget. Keys are raw bytes (32) — caller is
// responsible for hex/base64-encoding for transport if ever needed.
type ChatDBKeyStore interface {
	// Read returns the existing key for accountUUID. Returns a non-nil error
	// (errors.Is == os.ErrNotExist) when no key exists yet — caller should
	// generate via crypto/rand and Write.
	Read(ctx context.Context, accountUUID string) ([]byte, error)

	// Write stores key for accountUUID, overwriting any prior value.
	Write(ctx context.Context, accountUUID string, key []byte) error

	// Delete removes the key. Always called when an account is removed so
	// the leftover encrypted DB file (also deleted) becomes unrecoverable.
	Delete(ctx context.Context, accountUUID string) error
}
