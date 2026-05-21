// Package cloudsync encrypts and syncs account credentials via iCloud Drive.
//
// The encrypted bundle is written to:
//
//	~/Library/Mobile Documents/com~apple~CloudDocs/ClaudeBar/cloud-bundle.enc
//
// macOS's bird daemon picks it up and syncs it across all Macs signed into the
// same Apple ID with iCloud Drive enabled — no special entitlements required for
// non-sandboxed apps.
//
// Encryption: AES-256-GCM with a key derived from a user passphrase via scrypt.
// File layout:
//
//	bytes  0-3:   magic "CLBR"
//	bytes  4-5:   version uint16 big-endian (currently 1)
//	bytes  6-37:  scrypt salt (32 bytes random)
//	bytes  38-49: AES-GCM nonce (12 bytes random)
//	bytes 50-end: AES-GCM ciphertext + 16-byte tag
package cloudsync

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"golang.org/x/crypto/scrypt"
)

const (
	magic  = "CLBR"
	saltLen  = 32
	nonceLen = 12
	keyLen   = 32

	// bundleV1 used scrypt N=2^15 — kept for decrypting legacy bundles only.
	bundleV1      = uint16(1)
	scryptNV1     = 1 << 15

	// bundleV2 raised scrypt to N=2^17 (OWASP minimum). V2 bundles are still
	// readable but new pushes use V3.
	bundleV2  = uint16(2)
	scryptNV2 = 1 << 17

	// bundleV3 keeps V2's scrypt parameters but adds anti-rollback (Seq,
	// PrevHash), per-record UpdatedAt merge, and double-encrypted MCP
	// payloads in the plaintext JSON. The binary header layout is unchanged.
	bundleV3      = uint16(3)
	bundleVersion = bundleV3
	scryptN       = 1 << 17
	scryptR       = 8
	scryptP       = 1
)

// BundleMCPConnector is one local MCP connector inside the encrypted bundle.
//
// Payload carries provider-defined secret material copied from Keychain. In V3
// bundles it is **double-encrypted**: the plaintext secret is AES-GCM sealed
// with an HKDF-derived MCP sub-key (see EncryptMCPPayload / DecryptMCPPayload)
// before being placed here, then the outer JSON is itself AES-GCM encrypted.
// A debug dump of the decrypted bundle therefore exposes ciphertext only.
//
// V1/V2 bundles stored the raw secret here; readers must check
// PayloadEncrypted to know whether a second decrypt is required.
type BundleMCPConnector struct {
	Service          domain.MCPService `json:"service"`
	Payload          string            `json:"payload"`
	PayloadEncrypted bool              `json:"payloadEncrypted,omitempty"`
	Enabled          bool              `json:"enabled"`
	DisplayName      string            `json:"displayName,omitempty"`
	Account          string            `json:"account,omitempty"`
	Scopes           []string          `json:"scopes,omitempty"`
	ConnectedAt      time.Time         `json:"connectedAt,omitempty"`
	LastVerified     time.Time         `json:"lastVerified,omitempty"`
	NeedsReauth      bool              `json:"needsReauth,omitempty"`
}

// BundleAccount is one account entry inside the encrypted bundle.
//
// UpdatedAtTime (V3) is the authoritative per-record version timestamp used
// for last-writer-wins merge. UpdatedAt (string, V1/V2) is kept for backward
// compat — V3 readers populate both fields so older code continues to work.
type BundleAccount struct {
	Number           int                  `json:"number"`
	Email            string               `json:"email"`
	Nickname         string               `json:"nickname,omitempty"`
	OrganizationName string               `json:"organizationName,omitempty"`
	OrganizationUUID string               `json:"organizationUuid,omitempty"`
	CredentialBlob   string               `json:"credentialBlob"`
	MCPConnectors    []BundleMCPConnector `json:"mcpConnectors,omitempty"`
	UpdatedAt        string               `json:"updatedAt"`
	UpdatedAtTime    time.Time            `json:"updatedAtTime,omitempty"`
}

// CloudBundle is the plaintext payload stored inside the encrypted file.
//
// V3 adds Seq (monotonic counter per push) and PrevHash (SHA-256 of the
// previous bundle's ciphertext, hex). Together they form the hash chain used
// by sync_state.go to reject rollback attempts.
type CloudBundle struct {
	Version             int                  `json:"version"`
	Seq                 uint64               `json:"seq,omitempty"`
	PrevHash            string               `json:"prevHash,omitempty"`
	PushedAt            time.Time            `json:"pushedAt"`
	Accounts            []BundleAccount      `json:"accounts"`
	SharedMCPConnectors []BundleMCPConnector `json:"sharedMcpConnectors,omitempty"`
}

// BundlePathForTest may be set by test code to redirect bundle I/O to a temp
// file. Unlike an env-var override, this cannot be injected from outside the
// process — a caller must have source-level access to set it.
// Never set this in production code.
var BundlePathForTest string

// BundlePath returns the iCloud Drive path for the encrypted bundle.
func BundlePath() string {
	if BundlePathForTest != "" {
		return BundlePathForTest
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home,
		"Library", "Mobile Documents", "com~apple~CloudDocs",
		"ClaudeBar", "cloud-bundle.enc")
}

// Encrypt serialises bundle to JSON and encrypts it with the given passphrase.
func Encrypt(bundle *CloudBundle, passphrase string) ([]byte, error) {
	plaintext, err := json.MarshalIndent(bundle, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal: %w", err)
	}

	salt := make([]byte, saltLen)
	if _, err := io.ReadFull(rand.Reader, salt); err != nil {
		return nil, fmt.Errorf("rand salt: %w", err)
	}

	key, err := deriveKeyN(passphrase, salt, scryptN)
	if err != nil {
		return nil, err
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("aes: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("gcm: %w", err)
	}

	nonce := make([]byte, nonceLen)
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("rand nonce: %w", err)
	}

	ciphertext := gcm.Seal(nil, nonce, plaintext, nil)

	// Assemble file: magic(4) + version(2) + salt(32) + nonce(12) + ciphertext
	out := make([]byte, 0, 4+2+saltLen+nonceLen+len(ciphertext))
	out = append(out, []byte(magic)...)
	out = binary.BigEndian.AppendUint16(out, bundleVersion)
	out = append(out, salt...)
	out = append(out, nonce...)
	out = append(out, ciphertext...)
	return out, nil
}

// Decrypt reads the binary blob and returns the plaintext bundle.
// Supports V1 (scrypt N=2^15) and V2+ (scrypt N=2^17) bundles.
func Decrypt(data []byte, passphrase string) (*CloudBundle, error) {
	header := 4 + 2 + saltLen + nonceLen
	if len(data) < header+16 {
		return nil, errors.New("bundle too short")
	}
	if string(data[:4]) != magic {
		return nil, errors.New("not a ClaudeBar bundle (bad magic)")
	}
	version := binary.BigEndian.Uint16(data[4:6])
	salt := data[6 : 6+saltLen]
	nonce := data[6+saltLen : 6+saltLen+nonceLen]
	ciphertext := data[6+saltLen+nonceLen:]

	// Use the N that matches the version that encrypted this bundle. V2 and V3
	// share the same scrypt cost; only V1 was weaker.
	n := scryptN
	if version == bundleV1 {
		n = scryptNV1
	}
	key, err := deriveKeyN(passphrase, salt, n)
	if err != nil {
		return nil, err
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("aes: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("gcm: %w", err)
	}

	plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, errors.New("decryption failed — wrong passphrase or corrupted bundle")
	}

	var bundle CloudBundle
	if err := json.Unmarshal(plaintext, &bundle); err != nil {
		return nil, fmt.Errorf("unmarshal: %w", err)
	}
	return &bundle, nil
}

func deriveKeyN(passphrase string, salt []byte, n int) ([]byte, error) {
	key, err := scrypt.Key([]byte(passphrase), salt, n, scryptR, scryptP, keyLen)
	if err != nil {
		return nil, fmt.Errorf("scrypt: %w", err)
	}
	return key, nil
}
