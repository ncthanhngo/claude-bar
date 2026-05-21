package usecase

import (
	"context"
	"fmt"
	"os"
	"strings"
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

	// Read and decrypt outside the lock: decrypt is CPU-intensive and the window
	// between read and lock-acquire is small. A concurrent push that lands here
	// means the pull restores a bundle that is at most one push cycle stale —
	// acceptable for a best-effort sync.
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

	var failures []string
	for _, ba := range bundle.Accounts {
		bundleBlob := domain.CredentialBlob(ba.CredentialBlob)
		writeBlob := bundleBlob

		// Option A: prefer the fresher credential — if local backup parses and has
		// a higher expiresAt, keep it rather than overwriting with a stale bundle.
		localBlob, localErr := s.Backup.Read(ctx, ba.Number, ba.Email)
		if localErr == nil && localBlob != "" {
			bundlePayload, bErr := bundleBlob.Extract()
			localPayload, lErr := localBlob.Extract()
			if bErr == nil && lErr == nil && localPayload.ExpiresAt > bundlePayload.ExpiresAt {
				writeBlob = localBlob
			}
			// equal expiresAt → writeBlob stays bundleBlob (bundle wins = new-machine scenario)
		}
		// local empty or error → writeBlob stays bundleBlob (always write bundle for new accounts)

		// R6: collect write failures instead of aborting — one bad keychain slot
		// must not prevent the rest of the accounts from being restored.
		if writeErr := s.Backup.Write(ctx, ba.Number, ba.Email, writeBlob); writeErr != nil {
			failures = append(failures, fmt.Sprintf("account %d (%s): %v", ba.Number, ba.Email, writeErr))
			continue
		}

		// Upsert account in registry only for successfully written accounts.
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

	// R6: always save registry for all successfully written accounts.
	if saveErr := s.Registry.Save(ctx, reg); saveErr != nil {
		return fmt.Errorf("save registry: %w", saveErr)
	}

	// R1: validate pulled credentials immediately in the background rather than
	// waiting until the next scheduled refresh or switch attempt.
	// INVARIANT: RefreshAllTokens must never call s.Lock.Acquire — the file lock
	// is still held at this point (defer Release runs on function return).
	go func() {
		bgCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		_ = s.RefreshAllTokens(bgCtx)
	}()

	if len(failures) > 0 {
		return fmt.Errorf("partial restore (%d/%d): %s",
			len(bundle.Accounts)-len(failures), len(bundle.Accounts),
			strings.Join(failures, "; "))
	}
	return nil
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
