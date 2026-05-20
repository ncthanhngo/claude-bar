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
			// Active account: read from the live keychain entry.
			live, err := s.Live.Read(ctx)
			if err != nil || live == "" {
				continue
			}
			blob = string(live)
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
