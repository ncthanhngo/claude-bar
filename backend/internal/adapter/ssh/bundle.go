package ssh

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"filippo.io/age"
)

// BundleVersion bumps when the on-disk .cbssh shape changes incompatibly.
const BundleVersion = 1

// Bundle is what gets serialised inside the age envelope. Holds host
// metadata only — never private keys. The IdentityFile path tells the
// importing Mac which key it should already have in its ~/.ssh/.
type Bundle struct {
	Version int           `json:"version"`
	Hosts   []TrackedHost `json:"hosts"`
}

// ExportBundle encrypts hosts under a passphrase (age scrypt recipient) and
// writes the result to out. Suitable for the "Export to .cbssh" widget
// action: the user picks a path under ~/Downloads (NEVER iCloud-synced
// paths — caller responsibility to check).
func ExportBundle(ctx context.Context, hosts []TrackedHost, passphrase string, out io.Writer) error {
	if strings.TrimSpace(passphrase) == "" {
		return fmt.Errorf("passphrase required for bundle export")
	}
	recipient, err := age.NewScryptRecipient(passphrase)
	if err != nil {
		return fmt.Errorf("age scrypt recipient: %w", err)
	}
	// Default work-factor (currently 18) is appropriate for interactive use.

	bundle := Bundle{Version: BundleVersion, Hosts: hosts}
	body, err := json.MarshalIndent(bundle, "", "  ")
	if err != nil {
		return fmt.Errorf("bundle marshal: %w", err)
	}

	w, err := age.Encrypt(out, recipient)
	if err != nil {
		return fmt.Errorf("age encrypt: %w", err)
	}
	if _, err := io.Copy(w, bytes.NewReader(body)); err != nil {
		_ = w.Close()
		return fmt.Errorf("age write body: %w", err)
	}
	return w.Close()
}

// ImportBundle decrypts an .cbssh stream with the passphrase and returns the
// host list. Wrong passphrase fails clean (`age: incorrect passphrase`).
func ImportBundle(ctx context.Context, in io.Reader, passphrase string) (*Bundle, error) {
	if strings.TrimSpace(passphrase) == "" {
		return nil, fmt.Errorf("passphrase required for bundle import")
	}
	identity, err := age.NewScryptIdentity(passphrase)
	if err != nil {
		return nil, fmt.Errorf("age scrypt identity: %w", err)
	}
	r, err := age.Decrypt(in, identity)
	if err != nil {
		return nil, fmt.Errorf("age decrypt: %w", err)
	}
	body, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("age read body: %w", err)
	}
	var b Bundle
	if err := json.Unmarshal(body, &b); err != nil {
		return nil, fmt.Errorf("bundle decode: %w", err)
	}
	if b.Version > BundleVersion {
		return nil, fmt.Errorf("bundle version %d not supported (this build supports up to %d)", b.Version, BundleVersion)
	}
	return &b, nil
}

// ExportBundleFile is a thin convenience that wraps ExportBundle, opens
// `path` with 0600 perms, and warns when the path lives under
// ~/Library/Mobile Documents (the iCloud Drive root) so the caller can
// abort before secrets leak to iCloud.
func ExportBundleFile(ctx context.Context, hosts []TrackedHost, passphrase, path string) error {
	if strings.Contains(path, "/Library/Mobile Documents/") {
		return fmt.Errorf("refuse to write bundle into iCloud-synced path: %s", path)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	return ExportBundle(ctx, hosts, passphrase, f)
}

// ImportBundleFile reads + decrypts a .cbssh file.
func ImportBundleFile(ctx context.Context, path, passphrase string) (*Bundle, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return ImportBundle(ctx, f, passphrase)
}
