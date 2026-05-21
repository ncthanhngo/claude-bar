package usecase

import (
	"context"
	"errors"
	"fmt"
)

// SwitchAccount swaps the live Keychain credential to the given account number.
//
// Transaction:
//  1. Acquire file lock.
//  2. Read ~/.claude.json (needed for step 5 rollback).
//  3. Read target backup creds + refresh access token.
//  4. Write target creds to live Keychain slot.
//  5. Patch ~/.claude.json -> oauthAccount = target identity.
//  6. Update registry.activeAccountNumber.
//
// We intentionally do NOT read the live Keychain entry ("Claude Code-credentials")
// during a switch. That item is owned by the claude CLI and carries a per-app ACL
// that prompts the user on every access. Backups are kept fresh by AddAccount and
// the daily token refresh; the token refresh in step 3 handles stale access tokens.
func (s *Service) SwitchAccount(ctx context.Context, targetNum int) error {
	if err := s.Lock.Acquire(ctx); err != nil {
		return err
	}
	defer s.Lock.Release()

	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return err
	}
	target, ok := reg.Accounts[targetNum]
	if !ok {
		return fmt.Errorf("account %d not found", targetNum)
	}
	if reg.ActiveAccountNumber == targetNum {
		return errors.New("already active")
	}

	prevConfig, err := s.Config.Read(ctx)
	if err != nil {
		return err
	}

	// Step 3 — load target backup creds.
	targetCreds, err := s.Backup.Read(ctx, target.Number, target.Email)
	if err != nil {
		return fmt.Errorf("read target backup: %w", err)
	}
	if targetCreds == "" {
		return fmt.Errorf("no backup credentials for account %d", target.Number)
	}

	// Step 3b — refresh access token before activating.
	//
	// Claude Code continuously refreshes and rewrites the Keychain entry while
	// an account is active. If we restore a stale access token, Anthropic treats
	// it as revoked and forces a full re-login. Using refreshToken (long-lived)
	// to obtain a fresh access token prevents this.
	if payload, extractErr := targetCreds.Extract(); extractErr == nil && payload.RefreshToken != "" {
		if fresh, refreshErr := s.Refresh.Refresh(ctx, payload.RefreshToken); refreshErr == nil && fresh != nil {
			if refreshed, blobErr := targetCreds.WithRefreshed(fresh); blobErr == nil && refreshed != "" {
				targetCreds = refreshed
				// Persist the fresh token back so the next swap is also pre-warmed.
				_ = s.Backup.Write(ctx, target.Number, target.Email, refreshed)
			}
		}
		// If refresh fails, continue with stored creds — better than aborting.
	}

	// Step 4 — write live creds.
	if err := s.Live.Write(ctx, targetCreds); err != nil {
		return fmt.Errorf("write live creds: %w", err)
	}

	// Step 5 — patch ~/.claude.json oauthAccount in place. Rollback live creds on failure.
	newCfg := prevConfig
	if newCfg == nil {
		newCfg = &emptyConfig
	}
	if newCfg.Raw == nil {
		newCfg.Raw = map[string]any{}
	}
	newCfg.OAuthAccount = newOAuthAccount(target.Email, target.OrganizationName, target.OrganizationUUID)
	if err := s.Config.Write(ctx, newCfg); err != nil {
		// Rollback: restore the target account's backup as live creds.
		// Reading from backup avoids touching the claude-owned keychain item.
		if rollback, _ := s.Backup.Read(ctx, target.Number, target.Email); rollback != "" {
			_ = s.Live.Write(ctx, rollback)
		}
		return fmt.Errorf("write claude config: %w", err)
	}

	// Step 6 — update registry.
	reg.ActiveAccountNumber = targetNum
	if err := s.Registry.Save(ctx, reg); err != nil {
		return fmt.Errorf("save registry: %w", err)
	}
	return nil
}
