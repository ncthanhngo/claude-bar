package usecase

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// SnapshotActiveLive copies the currently-active account's live Keychain creds
// into its backup slot. Used before flows that overwrite the live slot outside
// claude-bar's control (notably `claude /login` for adding a new account), so a
// freshly-rotated refresh token is not lost when the live slot is replaced.
//
// No-op when no active account is configured (e.g. registry is empty during the
// very first add). Returns the snapshot error otherwise so callers can decide
// whether to treat it as best-effort.
func (s *Service) SnapshotActiveLive(ctx context.Context) error {
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
		return nil
	}
	// The live login may belong to someone else by now (`claude /login` run
	// outside claude-bar); copying it would overwrite this account's backup
	// with another account's tokens. Check Claude Code's own record of who
	// is logged in before and after reading live, so a login landing in
	// between is caught too.
	if err := s.liveIsAccount(ctx, active); err != nil {
		return err
	}
	blob, err := s.Live.Read(ctx)
	if err != nil {
		return fmt.Errorf("read active live credential: %w", err)
	}
	if err := s.liveIsAccount(ctx, active); err != nil {
		return err
	}
	if _, err := blob.Extract(); err != nil {
		return fmt.Errorf("parse active live credential: %w", err)
	}
	if err := s.Backup.Write(ctx, active.Number, active.Email, blob); err != nil {
		return fmt.Errorf("snapshot active backup credential: %w", err)
	}
	return nil
}

// ErrLiveIdentityMismatch means Claude Code is logged in to a different
// account than the registry's active one, so its login is not copied.
var ErrLiveIdentityMismatch = errors.New("Claude Code is logged in to a different account than the active one")

// liveIsAccount checks ~/.claude.json's oauthAccount against acc.
func (s *Service) liveIsAccount(ctx context.Context, acc *domain.Account) error {
	cfg, err := s.Config.Read(ctx)
	if err != nil {
		return fmt.Errorf("read Claude Code config: %w", err)
	}
	if cfg.OAuthAccount == nil || cfg.OAuthAccount.EmailAddress == "" {
		return fmt.Errorf("%w (no oauthAccount in Claude Code config)", ErrLiveIdentityMismatch)
	}
	sameEmail := strings.EqualFold(strings.TrimSpace(cfg.OAuthAccount.EmailAddress), strings.TrimSpace(acc.Email))
	org := cfg.OAuthAccount.OrganizationUUID
	sameOrg := org == "" || acc.OrganizationUUID == "" || org == acc.OrganizationUUID
	if !sameEmail || !sameOrg {
		return fmt.Errorf("%w (live: %s)", ErrLiveIdentityMismatch, cfg.OAuthAccount.EmailAddress)
	}
	return nil
}
