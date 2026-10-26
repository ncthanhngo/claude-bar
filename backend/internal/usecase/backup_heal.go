package usecase

import (
	"context"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// healWaitForSwap bounds how long a poll waits for an in-flight swap before
// skipping the heal until the next poll.
const healWaitForSwap = 500 * time.Millisecond

// healActiveBackup copies the live credential into the active account's
// backup when live is the newer copy. Claude Code rotates the live refresh
// token on its own, which revokes the copy in the backup; without this, the
// backup only caught up at the next swap-away snapshot, and a failed snapshot
// left the account needing a fresh login when switched back to.
//
// A wrong heal copies one account's login over another's, so it needs proof
// under swap.lock: ~/.claude.json still attributes the login to the account
// (re-read after acquiring the lock — a swap that finished while we waited
// changed it — and again after reading live, to catch a `claude /login`).
func (s *Service) healActiveBackup(ctx context.Context) {
	if s.Live == nil || s.Lock == nil || s.Config == nil {
		return
	}
	lockCtx, cancel := context.WithTimeout(ctx, healWaitForSwap)
	defer cancel()
	if err := s.Lock.Acquire(lockCtx); err != nil {
		return
	}
	defer s.Lock.Release()

	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return
	}
	acc := s.configActiveAccount(ctx, reg)
	if acc == nil {
		return
	}
	// Under the refresh lock too, so a concurrent refresh of this backup
	// can't land between the compare and the write. Same order as Switch.
	_ = s.withBackupLock(ctx, acc.Number, func() error {
		live, lp := s.usableLive(ctx)
		if lp == nil || !s.liveNewerThanBackup(ctx, acc, live, lp) {
			return nil
		}
		// Narrows (cannot close) the window of a `claude /login` that wrote
		// the Keychain but not yet ~/.claude.json.
		if again := s.configActiveAccount(ctx, reg); again == nil || again.Number != acc.Number {
			return nil
		}
		if err := s.Backup.Write(ctx, acc.Number, acc.Email, live); err != nil {
			s.logf("heal account %d: backup write failed: %v", acc.Number, err)
			return nil
		}
		s.logf("heal account %d: backup updated from live", acc.Number)
		return nil
	})
}

// configActiveAccount returns the registered account ~/.claude.json names
// as the live login, or nil when it names none.
func (s *Service) configActiveAccount(ctx context.Context, reg *domain.Registry) *domain.Account {
	cfg, err := s.Config.Read(ctx)
	if err != nil || cfg == nil || cfg.OAuthAccount == nil {
		return nil
	}
	num := reg.FindByIdentity(cfg.OAuthAccount.EmailAddress, cfg.OAuthAccount.OrganizationUUID)
	return reg.Accounts[num]
}

// usableLive returns the live credential when it carries both tokens.
func (s *Service) usableLive(ctx context.Context) (domain.CredentialBlob, *domain.OAuthPayload) {
	live, err := s.Live.Read(ctx)
	if err != nil || live == "" {
		return "", nil
	}
	p, err := live.Extract()
	if err != nil || p.AccessToken == "" || p.RefreshToken == "" {
		return "", nil
	}
	return live, p
}

// liveNewerThanBackup reports whether live differs from acc's backup and is
// at least as new. A backup that expires later was written after live (a
// re-login or add-account that only wrote the backup) and must not be
// overwritten with the older live copy.
func (s *Service) liveNewerThanBackup(ctx context.Context, acc *domain.Account, live domain.CredentialBlob, lp *domain.OAuthPayload) bool {
	backup, err := s.readBackupFresh(ctx, acc.Number, acc.Email)
	if err != nil {
		return false
	}
	if backup == live {
		return false
	}
	if bp, err := backup.Extract(); err == nil && bp.ExpiresAt > lp.ExpiresAt {
		return false
	}
	return true
}
