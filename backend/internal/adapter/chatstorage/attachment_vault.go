package chatstorage

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/crypto/chacha20poly1305"
)

// AttachmentVault writes / reads per-attachment files on disk encrypted with
// XChaCha20-Poly1305. Each file gets a fresh 24-byte nonce stored as hex on
// the parent attachment row. AAD binds the ciphertext to (accountUUID,
// attachmentID) so a file swapped between accounts fails authentication.
type AttachmentVault struct {
	aead        interface {
		Seal(dst, nonce, plaintext, additionalData []byte) []byte
		Open(dst, nonce, ciphertext, additionalData []byte) ([]byte, error)
		NonceSize() int
	}
	accountUUID string
	dir         string
}

// NewAttachmentVault returns a vault keyed by attachKey (must be 32 bytes,
// e.g. the second output of DeriveKeys). `dir` is the per-account encrypted
// attachments directory; created lazily on first Write.
func NewAttachmentVault(attachKey []byte, accountUUID, dir string) (*AttachmentVault, error) {
	aead, err := chacha20poly1305.NewX(attachKey)
	if err != nil {
		return nil, fmt.Errorf("xchacha20poly1305 init: %w", err)
	}
	return &AttachmentVault{aead: aead, accountUUID: accountUUID, dir: dir}, nil
}

// Write encrypts plaintext and writes it to `<dir>/<attachmentID>.enc`.
// Returns the file path and hex-encoded nonce — caller stores those on the
// attachment row.
func (v *AttachmentVault) Write(ctx context.Context, attachmentID string, plaintext []byte) (string, string, error) {
	if err := os.MkdirAll(v.dir, 0o700); err != nil {
		return "", "", fmt.Errorf("mkdir attachment dir: %w", err)
	}
	nonce := make([]byte, v.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", "", fmt.Errorf("nonce: %w", err)
	}
	aad := v.aad(attachmentID)
	ciphertext := v.aead.Seal(nil, nonce, plaintext, aad)

	path := filepath.Join(v.dir, attachmentID+".enc")
	if err := os.WriteFile(path, ciphertext, 0o600); err != nil {
		return "", "", fmt.Errorf("write attachment: %w", err)
	}
	return path, hex.EncodeToString(nonce), nil
}

// Read decrypts and returns the plaintext for the attachment. Returns the
// raw chacha20poly1305 error on AEAD failure (caller maps to a sentinel
// if needed) — tamper detection bubbles up here.
func (v *AttachmentVault) Read(ctx context.Context, attachmentID, filePath, nonceHex string) ([]byte, error) {
	nonce, err := hex.DecodeString(nonceHex)
	if err != nil {
		return nil, fmt.Errorf("decode nonce: %w", err)
	}
	ct, err := os.ReadFile(filePath)
	if err != nil {
		return nil, fmt.Errorf("read attachment file: %w", err)
	}
	pt, err := v.aead.Open(nil, nonce, ct, v.aad(attachmentID))
	if err != nil {
		return nil, fmt.Errorf("aead open: %w", err)
	}
	return pt, nil
}

// Remove deletes the encrypted file on disk. Safe to call when the file
// doesn't exist (returns nil).
func (v *AttachmentVault) Remove(ctx context.Context, filePath string) error {
	if err := os.Remove(filePath); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// aad binds the ciphertext to its (account, attachment) identity so a file
// copied between accounts or renamed fails authentication.
func (v *AttachmentVault) aad(attachmentID string) []byte {
	return []byte(v.accountUUID + "|" + attachmentID)
}
