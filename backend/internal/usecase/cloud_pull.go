package usecase

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/cloudsync"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// CloudPull decrypts the iCloud Drive bundle and restores all accounts.
// Existing accounts are overwritten; the active account is NOT changed.
func (s *Service) CloudPull(ctx context.Context, passphrase string) error {
	if passphrase == "" {
		return fmt.Errorf("passphrase must not be empty")
	}

	data, err := os.ReadFile(cloudsync.BundlePath())
	if err != nil {
		return fmt.Errorf("read bundle: %w", err)
	}

	bundle, err := cloudsync.Decrypt(data, passphrase)
	if err != nil {
		return err
	}

	if err := s.Lock.Acquire(ctx); err != nil {
		return err
	}
	defer s.Lock.Release()

	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return fmt.Errorf("load registry: %w", err)
	}
	restoreMCP := bundle.Version >= 2
	if restoreMCP {
		shared, err := s.restoreMCPConnectors(ctx, 0, bundle.SharedMCPConnectors)
		if err != nil {
			return err
		}
		reg.SharedMCPConnectors = shared
	}

	for _, ba := range bundle.Accounts {
		// Write credential into backup keychain.
		blob := domain.CredentialBlob(ba.CredentialBlob)
		if err := s.Backup.Write(ctx, ba.Number, ba.Email, blob); err != nil {
			return fmt.Errorf("restore credential for %s: %w", ba.Email, err)
		}

		// Upsert account in registry.
		if _, exists := reg.Accounts[ba.Number]; !exists {
			reg.Accounts[ba.Number] = &domain.Account{}
			reg.Sequence = append(reg.Sequence, ba.Number)
		}
		acc := reg.Accounts[ba.Number]
		acc.Number = ba.Number
		acc.Email = ba.Email
		acc.Nickname = ba.Nickname
		acc.OrganizationName = ba.OrganizationName
		acc.OrganizationUUID = ba.OrganizationUUID
		if restoreMCP {
			connectors, err := s.restoreMCPConnectors(ctx, ba.Number, ba.MCPConnectors)
			if err != nil {
				return err
			}
			acc.MCPConnectors = connectors
		}
		if acc.CreatedAt.IsZero() {
			acc.CreatedAt = time.Now().UTC()
		}
	}

	return s.Registry.Save(ctx, reg)
}

// CloudStatus returns metadata about the iCloud Drive bundle.
type CloudStatusResult struct {
	Exists   bool      `json:"exists"`
	Path     string    `json:"path"`
	PushedAt time.Time `json:"pushedAt,omitempty"`
	SizeKB   int64     `json:"sizeKb,omitempty"`
}

// CloudStatus checks whether a bundle exists and when it was last pushed.
func (s *Service) CloudStatus(_ context.Context) (*CloudStatusResult, error) {
	path := cloudsync.BundlePath()
	info, err := os.Stat(path)
	if err != nil {
		return &CloudStatusResult{Exists: false, Path: path}, nil
	}
	return &CloudStatusResult{
		Exists:   true,
		Path:     path,
		PushedAt: info.ModTime().UTC(),
		SizeKB:   info.Size() / 1024,
	}, nil
}

// CloudForget deletes the encrypted bundle from iCloud Drive.
func (s *Service) CloudForget(_ context.Context) error {
	err := os.Remove(cloudsync.BundlePath())
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

func (s *Service) restoreMCPConnectors(ctx context.Context, accountNum int, connectors []cloudsync.BundleMCPConnector) (domain.AccountConnectors, error) {
	if len(connectors) == 0 {
		if accountNum == 0 {
			for _, svc := range domain.AllMCPServices {
				if err := s.MCPSecrets.Delete(ctx, accountNum, svc); err != nil {
					return nil, fmt.Errorf("delete stale shared mcp secret %s: %w", svc, err)
				}
			}
		}
		return nil, nil
	}
	out := domain.AccountConnectors{}
	seen := map[domain.MCPService]bool{}
	for _, c := range connectors {
		if c.Service == "" || c.Payload == "" {
			continue
		}
		if err := s.MCPSecrets.Write(ctx, accountNum, c.Service, c.Payload); err != nil {
			return nil, fmt.Errorf("restore mcp secret %s/%d: %w", c.Service, accountNum, err)
		}
		out[c.Service] = &domain.MCPConnector{
			Enabled:      c.Enabled,
			DisplayName:  c.DisplayName,
			Account:      c.Account,
			Scopes:       append([]string(nil), c.Scopes...),
			ConnectedAt:  c.ConnectedAt,
			LastVerified: c.LastVerified,
			NeedsReauth:  c.NeedsReauth,
		}
		seen[c.Service] = true
	}
	for _, svc := range domain.AllMCPServices {
		if !seen[svc] {
			if err := s.MCPSecrets.Delete(ctx, accountNum, svc); err != nil {
				return nil, fmt.Errorf("delete stale mcp secret %s/%d: %w", svc, accountNum, err)
			}
		}
	}
	if len(out) == 0 {
		return nil, nil
	}
	return out, nil
}
