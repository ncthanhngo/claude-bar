package usecase

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/cloudsync"
)

// CloudExport encrypts the local registry + credentials + MCP secrets to an
// arbitrary file path (not the iCloud container). This is the cross-Apple-ID
// sharing path: the resulting file is hand-delivered (AirDrop, Slack, USB) to
// the recipient who imports it with the same passphrase.
//
// Differences vs CloudPush:
//   - Writes to a user-chosen path, no ring-buffer rotation, no sync-state
//     update — the bundle on the receiver's side is on a separate chain.
//   - No remote-merge: an exported file is a snapshot of THIS device, not the
//     merged view that iCloud needs to stay convergent.
//   - Seq/PrevHash stay zero so the recipient's anti-rollback check accepts
//     it as a fresh chain (V1/V2-equivalent handling).
//
// Same as CloudPush: refresh inactive tokens before encrypting so the exported
// bundle has the freshest possible credentials, and acquire the push lock so
// SwitchAccount can't half-rewrite live credentials mid-export.
func (s *Service) CloudExport(ctx context.Context, passphrase string, destPath string) error {
	if passphrase == "" {
		return fmt.Errorf("passphrase must not be empty")
	}
	if destPath == "" {
		return fmt.Errorf("destination path must not be empty")
	}

	if err := s.RefreshAllTokens(ctx); err != nil {
		var refreshErr *RefreshAllError
		if !errors.As(err, &refreshErr) || refreshErr.BlocksPush() {
			return fmt.Errorf("refresh inactive credentials before export: %w", err)
		}
	}

	if err := s.Lock.Acquire(ctx); err != nil {
		return fmt.Errorf("acquire export lock: %w", err)
	}
	defer s.Lock.Release()

	bundle, err := s.buildLocalBundle(ctx, passphrase)
	if err != nil {
		return err
	}

	encrypted, err := cloudsync.Encrypt(bundle, passphrase)
	if err != nil {
		return fmt.Errorf("encrypt: %w", err)
	}

	if dir := filepath.Dir(destPath); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return fmt.Errorf("create export dir: %w", err)
		}
	}
	if err := cloudsync.WriteBundleAtomic(destPath, encrypted); err != nil {
		return fmt.Errorf("write export: %w", err)
	}
	return nil
}

// CloudImportPreview decrypts an externally-supplied bundle file and returns
// the same side-by-side comparison rows as CloudPreview (iCloud slot path).
// Read-only — does not touch keychain or registry.
func (s *Service) CloudImportPreview(ctx context.Context, passphrase string, srcPath string) ([]CloudPreviewRow, error) {
	if passphrase == "" {
		return nil, fmt.Errorf("passphrase must not be empty")
	}
	if srcPath == "" {
		return nil, fmt.Errorf("source path must not be empty")
	}
	data, err := os.ReadFile(srcPath)
	if err != nil {
		return nil, fmt.Errorf("read bundle: %w", err)
	}
	bundle, err := cloudsync.Decrypt(data, passphrase)
	if err != nil {
		return nil, err
	}
	return s.previewBundleAgainstLocal(ctx, bundle)
}

// CloudImportSelective applies selected accounts from an externally-supplied
// bundle file. Like CloudRestoreBackup it bypasses anti-rollback (the imported
// bundle is on a different sync chain) and does NOT update sync state — the
// local iCloud chain is preserved for future Push/Pull against iCloud.
//
// identities is the set of "email|orgUUID" keys to apply (matches
// CloudPreviewRow.Identity). An empty set is rejected so the user doesn't
// accidentally no-op an import.
func (s *Service) CloudImportSelective(ctx context.Context, passphrase string, srcPath string, identities []string) error {
	if passphrase == "" {
		return fmt.Errorf("passphrase must not be empty")
	}
	if srcPath == "" {
		return fmt.Errorf("source path must not be empty")
	}
	if len(identities) == 0 {
		return fmt.Errorf("no accounts selected")
	}

	data, err := os.ReadFile(srcPath)
	if err != nil {
		return fmt.Errorf("read bundle: %w", err)
	}
	bundle, err := cloudsync.Decrypt(data, passphrase)
	if err != nil {
		return err
	}

	selected := make(map[string]bool, len(identities))
	for _, id := range identities {
		selected[id] = true
	}

	if err := s.Lock.Acquire(ctx); err != nil {
		return err
	}
	defer s.Lock.Release()

	return s.applyBundle(ctx, bundle, passphrase, selected)
}
