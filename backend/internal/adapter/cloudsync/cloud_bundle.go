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
	magic         = "CLBR"
	bundleVersion = uint16(1)
	saltLen       = 32
	nonceLen      = 12
	keyLen        = 32

	// scrypt parameters (N=2^15 ≈ 100ms on modern hardware, r=8, p=1)
	scryptN = 1 << 15
	scryptR = 8
	scryptP = 1
)

// BundleMCPConnector is one local MCP connector inside the encrypted bundle.
// Payload is provider-defined secret material copied from Keychain; this struct
// must only ever be written inside the AES-GCM encrypted cloud bundle.
type BundleMCPConnector struct {
	Service      domain.MCPService `json:"service"`
	Payload      string            `json:"payload"`
	Enabled      bool              `json:"enabled"`
	DisplayName  string            `json:"displayName,omitempty"`
	Account      string            `json:"account,omitempty"`
	Scopes       []string          `json:"scopes,omitempty"`
	ConnectedAt  time.Time         `json:"connectedAt,omitempty"`
	LastVerified time.Time         `json:"lastVerified,omitempty"`
	NeedsReauth  bool              `json:"needsReauth,omitempty"`
}

// BundleAccount is one account entry inside the encrypted bundle.
type BundleAccount struct {
	Number           int                  `json:"number"`
	Email            string               `json:"email"`
	Nickname         string               `json:"nickname,omitempty"`
	OrganizationName string               `json:"organizationName,omitempty"`
	OrganizationUUID string               `json:"organizationUuid,omitempty"`
	CredentialBlob   string               `json:"credentialBlob"`
	MCPConnectors    []BundleMCPConnector `json:"mcpConnectors,omitempty"`
	UpdatedAt        string               `json:"updatedAt"`
}

// CloudBundle is the plaintext payload stored inside the encrypted file.
type CloudBundle struct {
	Version             int                  `json:"version"`
	PushedAt            time.Time            `json:"pushedAt"`
	Accounts            []BundleAccount      `json:"accounts"`
	SharedMCPConnectors []BundleMCPConnector `json:"sharedMcpConnectors,omitempty"`
}

// BundlePath returns the iCloud Drive path for the encrypted bundle.
func BundlePath() string {
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

	key, err := deriveKey(passphrase, salt)
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
func Decrypt(data []byte, passphrase string) (*CloudBundle, error) {
	header := 4 + 2 + saltLen + nonceLen
	if len(data) < header+16 {
		return nil, errors.New("bundle too short")
	}
	if string(data[:4]) != magic {
		return nil, errors.New("not a ClaudeBar bundle (bad magic)")
	}
	// version := binary.BigEndian.Uint16(data[4:6]) — reserved for future migration
	salt := data[6 : 6+saltLen]
	nonce := data[6+saltLen : 6+saltLen+nonceLen]
	ciphertext := data[6+saltLen+nonceLen:]

	key, err := deriveKey(passphrase, salt)
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

func deriveKey(passphrase string, salt []byte) ([]byte, error) {
	key, err := scrypt.Key([]byte(passphrase), salt, scryptN, scryptR, scryptP, keyLen)
	if err != nil {
		return nil, fmt.Errorf("scrypt: %w", err)
	}
	return key, nil
}
