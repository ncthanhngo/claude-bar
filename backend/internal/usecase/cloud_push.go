package usecase

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/cloudsync"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// CloudPush reads all accounts + backup credentials, encrypts them with the
// given passphrase, and writes the bundle to iCloud Drive.
func (s *Service) CloudPush(ctx context.Context, passphrase string) error {
	if passphrase == "" {
		return fmt.Errorf("passphrase must not be empty")
	}

	// Option B: refresh inactive tokens before acquiring the lock so the bundle
	// contains fresh credentials without holding the lock during network calls.
	// A failed refresh means at least one inactive backup cannot be swapped to
	// on the destination either, so do not publish a bundle that looks healthy.
	if err := s.RefreshAllTokens(ctx); err != nil {
		return fmt.Errorf("refresh inactive credentials before push: %w", err)
	}

	// R5: acquire the file lock before reading any keychain data to serialise
	// against SwitchAccount, which also holds the lock while overwriting live.
	if err := s.Lock.Acquire(ctx); err != nil {
		return fmt.Errorf("acquire push lock: %w", err)
	}
	defer s.Lock.Release()

	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return fmt.Errorf("load registry: %w", err)
	}

	bundle := &cloudsync.CloudBundle{
		Version:  2,
		PushedAt: time.Now().UTC(),
	}
	sharedConnectors, err := s.bundleMCPConnectors(ctx, 0, reg.SharedMCPConnectors)
	if err != nil {
		return err
	}
	bundle.SharedMCPConnectors = sharedConnectors

	for _, acc := range reg.Accounts {
		var blob string
		if acc.Number == reg.ActiveAccountNumber {
			// R2: active account must be in the bundle. Fall back to backup if the
			// live read fails; fail loudly if neither is available so the caller
			// knows the bundle would be incomplete.
			live, liveErr := s.Live.Read(ctx)
			if liveErr != nil || live == "" {
				bak, _ := s.Backup.Read(ctx, acc.Number, acc.Email)
				if bak == "" {
					return fmt.Errorf("active account %d (%s): live credential unreadable and no backup — cannot push", acc.Number, acc.Email)
				}
				blob = string(bak)
			} else {
				blob = string(live)
			}
		} else {
			bak, err := s.Backup.Read(ctx, acc.Number, acc.Email)
			if err != nil || bak == "" {
				continue
			}
			blob = string(bak)
		}
		connectors, err := s.bundleMCPConnectors(ctx, acc.Number, acc.MCPConnectors)
		if err != nil {
			return err
		}
		bundle.Accounts = append(bundle.Accounts, cloudsync.BundleAccount{
			Number:           acc.Number,
			Email:            acc.Email,
			Nickname:         acc.Nickname,
			OrganizationName: acc.OrganizationName,
			OrganizationUUID: acc.OrganizationUUID,
			CredentialBlob:   blob,
			MCPConnectors:    connectors,
			UpdatedAt:        acc.CreatedAt.UTC().Format(time.RFC3339),
		})
	}

	if len(bundle.Accounts) == 0 {
		return fmt.Errorf("no accounts with credentials to push")
	}

	encrypted, err := cloudsync.Encrypt(bundle, passphrase)
	if err != nil {
		return fmt.Errorf("encrypt: %w", err)
	}

	dest := cloudsync.BundlePath()
	if err := os.MkdirAll(filepath.Dir(dest), 0o700); err != nil {
		return fmt.Errorf("create iCloud dir: %w", err)
	}
	if err := os.WriteFile(dest, encrypted, 0o600); err != nil {
		return fmt.Errorf("write bundle: %w", err)
	}
	return nil
}

func (s *Service) bundleMCPConnectors(ctx context.Context, accountNum int, metas domain.AccountConnectors) ([]cloudsync.BundleMCPConnector, error) {
	if len(metas) == 0 {
		return nil, nil
	}
	out := make([]cloudsync.BundleMCPConnector, 0, len(metas))
	for _, svc := range domain.AllMCPServices {
		meta, ok := metas[svc]
		if !ok || meta == nil {
			continue
		}
		payload, err := s.MCPSecrets.Read(ctx, accountNum, svc)
		if err != nil {
			return nil, fmt.Errorf("read mcp secret %s/%d: %w", svc, accountNum, err)
		}
		if payload == "" {
			continue
		}
		out = append(out, cloudsync.BundleMCPConnector{
			Service:      svc,
			Payload:      payload,
			Enabled:      meta.Enabled,
			DisplayName:  meta.DisplayName,
			Account:      meta.Account,
			Scopes:       append([]string(nil), meta.Scopes...),
			ConnectedAt:  meta.ConnectedAt,
			LastVerified: meta.LastVerified,
			NeedsReauth:  meta.NeedsReauth,
		})
	}
	return out, nil
}
