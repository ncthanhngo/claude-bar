// Package chatstorage implements port.ChatStorage on top of one per-account
// SQLCipher database (encrypt-at-rest) plus an on-disk attachment vault
// (XChaCha20-Poly1305). Each account gets its own master key in the
// macOS Keychain; two sub-keys (one for SQLCipher, one for the vault)
// are derived via HKDF so a compromise of one path doesn't leak the other.
package chatstorage

import (
	"crypto/sha256"
	"io"

	"golang.org/x/crypto/hkdf"
)

const (
	// MasterKeySize is the byte length of the per-account master key that
	// lives in the Keychain. 32 bytes (256 bits) — feeds HKDF.
	MasterKeySize = 32

	// hkdfInfoVersion is the static "info" label fed to HKDF. Bumping it
	// invalidates every existing derived key — only do this for a key
	// rotation scheme migration (none planned for MVP).
	hkdfInfoVersion = "claude-bar-chat-v1"
)

// DeriveKeys takes a 32-byte master and produces (dbKey, attachmentKey).
// Deterministic — same master always yields the same sub-keys (required so
// re-opening the DB after app restart succeeds without re-encrypting).
//
// HKDF-Extract uses an empty salt (we don't have a stable per-account salt
// independent of the master, and the master itself comes from CSPRNG).
func DeriveKeys(master []byte) (dbKey, attachKey []byte) {
	r := hkdf.New(sha256.New, master, nil, []byte(hkdfInfoVersion))
	dbKey = make([]byte, 32)
	_, _ = io.ReadFull(r, dbKey)
	attachKey = make([]byte, 32)
	_, _ = io.ReadFull(r, attachKey)
	return
}
