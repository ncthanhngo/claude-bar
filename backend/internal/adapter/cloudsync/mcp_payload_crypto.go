// Double-encryption for MCP payloads.
//
// The outer bundle is already AES-GCM encrypted, but a user who debug-dumps
// the *decrypted* JSON exposes every connector secret in plaintext. To prevent
// that, V3 bundles wrap each MCP secret in a second AES-GCM layer keyed by an
// HKDF sub-key derived from the bundle passphrase. The same passphrase opens
// both layers, but the decrypted-JSON dump only shows ciphertext blobs.
//
// Layout of an encrypted MCP payload (base64 of):
//
//	bytes  0-31: salt (32 bytes — per-payload, makes HKDF deterministic per record)
//	bytes 32-43: AES-GCM nonce (12 bytes)
//	bytes 44-end: ciphertext + 16-byte tag
//
// The HKDF info string ("claude-bar/mcp-payload-v1") domain-separates this
// sub-key from any other use of the bundle passphrase.
package cloudsync

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"

	"golang.org/x/crypto/hkdf"
)

const (
	mcpPayloadSaltLen  = 32
	mcpPayloadNonceLen = 12
	mcpPayloadInfo     = "claude-bar/mcp-payload-v1"
)

// EncryptMCPPayload seals a plaintext MCP secret with a passphrase-derived
// sub-key. The returned string is base64 of {salt || nonce || ciphertext}.
func EncryptMCPPayload(plaintext, passphrase string) (string, error) {
	if plaintext == "" {
		return "", nil
	}
	salt := make([]byte, mcpPayloadSaltLen)
	if _, err := io.ReadFull(rand.Reader, salt); err != nil {
		return "", fmt.Errorf("rand salt: %w", err)
	}
	key, err := mcpSubKey(passphrase, salt)
	if err != nil {
		return "", err
	}
	gcm, err := newGCM(key)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, mcpPayloadNonceLen)
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return "", fmt.Errorf("rand nonce: %w", err)
	}
	ct := gcm.Seal(nil, nonce, []byte(plaintext), nil)

	out := make([]byte, 0, len(salt)+len(nonce)+len(ct))
	out = append(out, salt...)
	out = append(out, nonce...)
	out = append(out, ct...)
	return base64.StdEncoding.EncodeToString(out), nil
}

// DecryptMCPPayload reverses EncryptMCPPayload.
func DecryptMCPPayload(encoded, passphrase string) (string, error) {
	if encoded == "" {
		return "", nil
	}
	blob, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return "", fmt.Errorf("base64 decode: %w", err)
	}
	if len(blob) < mcpPayloadSaltLen+mcpPayloadNonceLen+16 {
		return "", errors.New("mcp payload too short")
	}
	salt := blob[:mcpPayloadSaltLen]
	nonce := blob[mcpPayloadSaltLen : mcpPayloadSaltLen+mcpPayloadNonceLen]
	ct := blob[mcpPayloadSaltLen+mcpPayloadNonceLen:]

	key, err := mcpSubKey(passphrase, salt)
	if err != nil {
		return "", err
	}
	gcm, err := newGCM(key)
	if err != nil {
		return "", err
	}
	pt, err := gcm.Open(nil, nonce, ct, nil)
	if err != nil {
		return "", errors.New("mcp payload decrypt failed — wrong passphrase or corrupted record")
	}
	return string(pt), nil
}

// mcpSubKey derives a 32-byte sub-key from the passphrase using HKDF-SHA256
// with a per-payload salt and a fixed domain-separation info string.
//
// HKDF (not scrypt) is correct here because the input "passphrase" has already
// been stretched once for the outer bundle key — running scrypt again would
// burn time without adding entropy. HKDF cheaply derives independent sub-keys
// from a single high-entropy secret.
func mcpSubKey(passphrase string, salt []byte) ([]byte, error) {
	r := hkdf.New(sha256.New, []byte(passphrase), salt, []byte(mcpPayloadInfo))
	key := make([]byte, keyLen)
	if _, err := io.ReadFull(r, key); err != nil {
		return nil, fmt.Errorf("hkdf: %w", err)
	}
	return key, nil
}

func newGCM(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("aes: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("gcm: %w", err)
	}
	return gcm, nil
}
