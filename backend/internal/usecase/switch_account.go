package usecase

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// freshAccessTokenWindow is the minimum runway remaining on a backup's
// access token before we trust it for an immediate swap without calling
// the OAuth refresh endpoint. Wide enough that the freshly-installed token
// survives at least one Claude Code internal refresh cycle; narrow enough
// that the live slot always boots with a usable AT.
const freshAccessTokenWindow = 10 * time.Minute

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

	prevConfig, err := s.Config.Read(ctx)
	if err != nil {
		return err
	}
	activeNum := activeAccountNumber(reg, prevConfig)
	if activeNum == targetNum {
		if reg.ActiveAccountNumber != targetNum {
			return s.adoptConfigActiveAccount(ctx, reg, target)
		}
		return s.repairActiveAccountState(ctx, target)
	}

	// Before the snapshot, so a refresh Claude Code has in flight for the
	// outgoing account lands first: the snapshot then captures its rotated
	// refresh token, and nothing overwrites the target credential below.
	if err := s.waitClaudeRefreshLock(ctx); err != nil {
		return err
	}

	if active, ok := reg.Accounts[activeNum]; ok && active != nil {
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
		if active, ok := reg.Accounts[activeNum]; ok && active != nil {
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

func (s *Service) adoptConfigActiveAccount(ctx context.Context, reg *domain.Registry, acc *domain.Account) error {
	// The live Claude config says this account is already active. Refresh its
	// backup from live when possible so a later switch-back does not depend on a
	// stale refresh token, but do not block registry recovery on Keychain read.
	_ = s.snapshotLiveCredential(ctx, acc)
	reg.ActiveAccountNumber = acc.Number
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
	// When ~/.claude.json proves the live login is acc, live is the newest
	// copy: Claude Code may have rotated its refresh token since the backup
	// was taken, so overwriting live from the backup would log it out. Keep
	// live and bring the backup up to date instead.
	if s.liveProvenFor(ctx, acc) {
		return s.snapshotLiveCredential(ctx, acc)
	}
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

// liveProvenFor reports whether ~/.claude.json attributes the live login to
// acc and live is usable and at least as new as acc's backup.
func (s *Service) liveProvenFor(ctx context.Context, acc *domain.Account) bool {
	cfg, err := s.Config.Read(ctx)
	if err != nil || cfg == nil || cfg.OAuthAccount == nil ||
		cfg.OAuthAccount.EmailAddress != acc.Email || cfg.OAuthAccount.OrganizationUUID != acc.OrganizationUUID {
		return false
	}
	live, lp := s.usableLive(ctx)
	if lp == nil {
		return false
	}
	backup, err := s.readBackupFresh(ctx, acc.Number, acc.Email)
	if err != nil {
		return false
	}
	if bp, err := backup.Extract(); err == nil && backup != live && bp.ExpiresAt > lp.ExpiresAt {
		return false
	}
	return true
}

func (s *Service) rewriteLiveCredentialFromBackup(ctx context.Context, acc *domain.Account) error {
	creds, err := s.credentialFromBackup(ctx, acc, false)
	if err != nil {
		return err
	}
	if err := s.waitClaudeRefreshLock(ctx); err != nil {
		return err
	}
	if err := s.Live.Write(ctx, creds); err != nil {
		return fmt.Errorf("write live creds: %w", err)
	}
	return nil
}

// waitClaudeRefreshLock keeps a refresh Claude Code has in flight for the
// current live account from landing on top of the credential written next.
// Returns ctx's error so a cancelled swap stops before touching the live slot.
func (s *Service) waitClaudeRefreshLock(ctx context.Context) error {
	if s.RefreshLock != nil {
		s.RefreshLock.WaitReleased(ctx)
	}
	return ctx.Err()
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
	// Fallback for repair (ACL recovery, offline): whatever the backup holds.
	creds, err := s.Backup.Read(ctx, acc.Number, acc.Email)
	if err != nil {
		return "", fmt.Errorf("read target backup: %w", err)
	}
	if creds == "" {
		return "", fmt.Errorf("no backup credentials for account %d", acc.Number)
	}

	// Read and (when the access token is short on runway) refresh under the
	// refresh lock, from the Keychain itself: another csw process may be
	// rotating this backup right now, and installing its pre-rotation copy
	// into live would hand Claude Code an already-revoked refresh token. A
	// switch requires a proven token so it never installs a broken login;
	// every rotation risks the single-use token, so refresh only when needed.
	var out domain.CredentialBlob
	err = s.withBackupLock(ctx, acc.Number, func() error {
		blob, _, err := s.refreshBackupLocked(ctx, acc.Number, acc.Email, false, requireRefresh)
		out = blob
		return err
	})
	switch {
	case err == nil:
		return out, nil
	case errors.Is(err, errSharedWithLive):
		// Claude Code already owns this login and keeps it fresh.
		return creds, nil
	case requireRefresh:
		return "", classifyBackupRefreshError(acc.Number, err)
	default:
		return creds, nil
	}
}

func accessTokenHasRunway(p *domain.OAuthPayload, window time.Duration) bool {
	if p == nil || p.AccessToken == "" || p.ExpiresAt == 0 {
		return false
	}
	return time.Until(time.UnixMilli(p.ExpiresAt)) > window
}

// classifyBackupRefreshError differentiates a permanent re-login condition
// (invalid_grant) from transient OAuth failures (429 rate-limit, network,
// 5xx). Previously every refresh error surfaced as "credentials need login
// again", which sent users hunting for a re-login flow they did not need
// — a 429 from a background refresh storm self-clears within minutes.
func classifyBackupRefreshError(num int, err error) error {
	switch {
	case errors.Is(err, errIncompleteRefresh), errors.Is(err, errNoRefreshToken):
		return fmt.Errorf("account %d credentials need login again: %w", num, err)
	case isInvalidGrant(err):
		return fmt.Errorf("account %d credentials need login again: refresh backup token: %w", num, err)
	case isRateLimited(err):
		return fmt.Errorf("account %d swap deferred: OAuth refresh %w (no re-login needed; retry shortly)", num, err)
	default:
		return fmt.Errorf("account %d swap deferred: refresh backup token transiently failed: %w (retry shortly; no re-login needed)", num, err)
	}
}
