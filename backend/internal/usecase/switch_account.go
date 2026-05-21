package usecase

import (
	"context"
	"errors"
	"fmt"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// SwitchAccount swaps the live Keychain credential to the given account number.
//
// Transaction:
//  1. Acquire file lock.
//  2. Read ~/.claude.json (needed for step 6 rollback).
//  3. Snapshot the account currently active in Claude Code (best-effort).
//  4. Read target backup creds + refresh access token.
//  5. Write target creds to live Keychain slot.
//  6. Patch ~/.claude.json -> oauthAccount = target identity.
//  7. Update registry.activeAccountNumber.
//
// Step 3 is best-effort: if the live Keychain read fails (ACL denied, transient
// error) the switch continues. A successful snapshot means rollback (on step 6
// failure) restores the freshest credential; a failed snapshot degrades to the
// pre-existing backup, which is still a valid restore point.
//
// Claude Code can rotate the active account's refresh token while it is running.
// Snapshotting its live Keychain entry before overwrite keeps that account's
// backup usable for a later switch back.
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
		return s.repairActiveAccountState(ctx, target)
	}

	prevConfig, err := s.Config.Read(ctx)
	if err != nil {
		return err
	}

	if active, ok := reg.Accounts[reg.ActiveAccountNumber]; ok && active != nil {
		// Best-effort: failure (Keychain ACL denied, transient read error) must not
		// block the switch. Rollback degrades to pre-existing backup in that case.
		_ = s.snapshotLiveCredential(ctx, active)
	}

	targetCreds, err := s.credentialFromBackup(ctx, target, true)
	if err != nil {
		return err
	}

	// Step 5 — write live creds.
	if err := s.Live.Write(ctx, targetCreds); err != nil {
		return fmt.Errorf("write live creds: %w", err)
	}

	// Step 6 — patch ~/.claude.json oauthAccount in place. Rollback live creds on failure.
	newCfg := prevConfig
	if newCfg == nil {
		newCfg = &emptyConfig
	}
	if newCfg.Raw == nil {
		newCfg.Raw = map[string]any{}
	}
	newCfg.OAuthAccount = newOAuthAccount(target.Email, target.OrganizationName, target.OrganizationUUID)
	if err := s.Config.Write(ctx, newCfg); err != nil {
		// Rollback: restore the previously-active account's credential to live.
		// If step 3 (snapshot) succeeded, this is the fresh live cred written there.
		// If step 3 failed (best-effort), this is the pre-existing backup — still a
		// valid restore point. Either way, live and ~/.claude.json stay consistent.
		if active, ok := reg.Accounts[reg.ActiveAccountNumber]; ok && active != nil {
			if prev, _ := s.Backup.Read(ctx, active.Number, active.Email); prev != "" {
				if rollbackErr := s.Live.Write(ctx, prev); rollbackErr != nil {
					return fmt.Errorf("write claude config: %w; rollback write live: %w", err, rollbackErr)
				}
			}
		}
		return fmt.Errorf("write claude config: %w", err)
	}

	// Step 7 — update registry.
	reg.ActiveAccountNumber = targetNum
	if err := s.Registry.Save(ctx, reg); err != nil {
		return fmt.Errorf("save registry: %w", err)
	}
	return nil
}

// RepairLiveCredential rewrites the live Claude Code Keychain item from the
// active account backup. It is intentionally read-free for the live item, so it
// can repair a bad ACL without triggering the same macOS permission prompt.
func (s *Service) RepairLiveCredential(ctx context.Context) error {
	if err := s.Lock.Acquire(ctx); err != nil {
		return err
	}
	defer s.Lock.Release()

	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return err
	}
	active, ok := reg.Accounts[reg.ActiveAccountNumber]
	if !ok || active == nil {
		return errors.New("no active account")
	}
	return s.rewriteLiveCredentialFromBackup(ctx, active)
}

func (s *Service) repairActiveAccountState(ctx context.Context, acc *domain.Account) error {
	if err := s.rewriteLiveCredentialFromBackup(ctx, acc); err != nil {
		return err
	}

	cfg, err := s.Config.Read(ctx)
	if err != nil {
		return fmt.Errorf("read claude config: %w", err)
	}
	if cfg == nil {
		cfg = &emptyConfig
	}
	if cfg.Raw == nil {
		cfg.Raw = map[string]any{}
	}
	cfg.OAuthAccount = newOAuthAccount(acc.Email, acc.OrganizationName, acc.OrganizationUUID)
	if err := s.Config.Write(ctx, cfg); err != nil {
		return fmt.Errorf("write claude config: %w", err)
	}
	return nil
}

func (s *Service) rewriteLiveCredentialFromBackup(ctx context.Context, acc *domain.Account) error {
	creds, err := s.credentialFromBackup(ctx, acc, false)
	if err != nil {
		return err
	}
	if err := s.Live.Write(ctx, creds); err != nil {
		return fmt.Errorf("write live creds: %w", err)
	}
	return nil
}

func (s *Service) snapshotLiveCredential(ctx context.Context, acc *domain.Account) error {
	blob, err := s.Live.Read(ctx)
	if err != nil {
		return fmt.Errorf("read active live credential: %w", err)
	}
	if blob == "" {
		return errors.New("active live credential is empty")
	}
	if _, err := blob.Extract(); err != nil {
		return fmt.Errorf("parse active live credential: %w", err)
	}
	if err := s.Backup.Write(ctx, acc.Number, acc.Email, blob); err != nil {
		return fmt.Errorf("snapshot active backup credential: %w", err)
	}
	return nil
}

func (s *Service) credentialFromBackup(ctx context.Context, acc *domain.Account, requireRefresh bool) (domain.CredentialBlob, error) {
	creds, err := s.Backup.Read(ctx, acc.Number, acc.Email)
	if err != nil {
		return "", fmt.Errorf("read target backup: %w", err)
	}
	if creds == "" {
		return "", fmt.Errorf("no backup credentials for account %d", acc.Number)
	}

	// Refresh access token before activating when the backup can still refresh.
	// Older backups may already have a rotated refresh token; snapshotting the
	// live credential before switch-away keeps future backups fresh. A switch
	// requires a proven refresh so it does not install a broken login into the
	// live slot; repair keeps its fallback for ACL recovery and offline cases.
	payload, err := creds.Extract()
	if err != nil {
		return "", fmt.Errorf("parse backup credential: %w", err)
	}
	if payload.RefreshToken == "" {
		if requireRefresh {
			return "", fmt.Errorf("account %d credentials need login again: backup has no refresh token", acc.Number)
		}
		return creds, nil
	}

	unlock := s.lockBackupRefresh(acc.Number)
	defer unlock()

	fresh, err := s.Refresh.Refresh(ctx, payload.RefreshToken)
	if err != nil {
		if requireRefresh {
			return "", fmt.Errorf("account %d credentials need login again: refresh backup token: %w", acc.Number, err)
		}
		return creds, nil
	}
	if fresh == nil {
		if requireRefresh {
			return "", fmt.Errorf("account %d credentials need login again: refresh returned no token", acc.Number)
		}
		return creds, nil
	}
	if fresh.AccessToken == "" || fresh.RefreshToken == "" {
		if requireRefresh {
			return "", fmt.Errorf("account %d credentials need login again: refresh returned incomplete token", acc.Number)
		}
		return creds, nil
	}

	refreshed, err := creds.WithRefreshed(fresh)
	if err != nil {
		if requireRefresh {
			return "", fmt.Errorf("account %d credentials need login again: store refreshed backup token: %w", acc.Number, err)
		}
		return creds, nil
	}
	if refreshed == "" {
		if requireRefresh {
			return "", fmt.Errorf("account %d credentials need login again: refreshed backup token is empty", acc.Number)
		}
		return creds, nil
	}

	// Persist the fresh token back so the next swap is also pre-warmed.
	_ = s.Backup.Write(ctx, acc.Number, acc.Email, refreshed)
	return refreshed, nil
}
