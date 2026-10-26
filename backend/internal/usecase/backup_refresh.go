package usecase

import (
	"context"
	"errors"
	"fmt"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// errRefreshLockBusy means another csw process held the refresh lock until
// ctx ran out — transient, never a reason to ask for a new login.
var errRefreshLockBusy = errors.New("backup refresh lock busy")

// errIncompleteRefresh means the token endpoint answered without a usable
// token pair; the account needs a new login.
var errIncompleteRefresh = errors.New("refresh returned incomplete token")

// errNoRefreshToken means the backup cannot be renewed; needs a new login.
var errNoRefreshToken = errors.New("backup has no refresh token")

// errSharedWithLive means the backup's refresh token is the one Claude Code
// is using right now (registry and live disagree about who is active).
// Spending it would log the live session out, so it is left alone.
var errSharedWithLive = errors.New("refresh token is in use by the live Claude Code login")

// freshBackupReader is implemented by stores that cache reads in memory.
// Under the refresh lock the backup must come from the Keychain itself:
// another csw process may have rotated it since this process cached it.
type freshBackupReader interface {
	ReadFresh(ctx context.Context, accountNum int, email string) (domain.CredentialBlob, error)
}

func (s *Service) readBackupFresh(ctx context.Context, num int, email string) (domain.CredentialBlob, error) {
	if f, ok := s.Backup.(freshBackupReader); ok {
		return f.ReadFresh(ctx, num, email)
	}
	return s.Backup.Read(ctx, num, email)
}

// withBackupLock runs fn holding the per-account in-process mutex and the
// cross-process refresh lock. Refresh tokens are single-use and every csw
// command is its own process, so this is what keeps two commands from
// spending the same token (the loser gets invalid_grant).
func (s *Service) withBackupLock(ctx context.Context, num int, fn func() error) error {
	unlock := s.lockBackupRefresh(num)
	defer unlock()
	if s.BackupRefreshLock != nil {
		l := s.BackupRefreshLock()
		if err := l.Acquire(ctx); err != nil {
			return fmt.Errorf("%w: %v", errRefreshLockBusy, err)
		}
		defer l.Release()
	}
	return fn()
}

// refreshBackup takes the refresh lock and rotates the account's backup.
// force rotates even a backup whose access token still has runway (verify
// after a 401, the manual "refresh now" button).
func (s *Service) refreshBackup(ctx context.Context, num int, email string, force bool) (domain.CredentialBlob, *domain.OAuthPayload, error) {
	var blob domain.CredentialBlob
	var payload *domain.OAuthPayload
	err := s.withBackupLock(ctx, num, func() error {
		var err error
		blob, payload, err = s.refreshBackupLocked(ctx, num, email, force, true)
		return err
	})
	return blob, payload, err
}

// refreshBackupLocked reads the backup fresh and rotates it unless (without
// force) its access token still has runway — e.g. another process rotated it
// while this one waited for the lock. Persists the result. Caller holds
// withBackupLock. Returns the raw refresher error so callers can classify
// 429 vs invalid_grant.
//
// checkLive guards against spending the live session's token; the repair
// path skips it (it overwrites live anyway, and must not read the live item
// whose ACL it is repairing).
func (s *Service) refreshBackupLocked(ctx context.Context, num int, email string, force, checkLive bool) (domain.CredentialBlob, *domain.OAuthPayload, error) {
	blob, err := s.readBackupFresh(ctx, num, email)
	if err != nil {
		return "", nil, fmt.Errorf("read backup credential: %w", err)
	}
	if blob == "" {
		return "", nil, errors.New("no backup credentials")
	}
	payload, err := blob.Extract()
	if err != nil {
		return "", nil, fmt.Errorf("parse backup credential: %w", err)
	}
	if !force && accessTokenHasRunway(payload, freshAccessTokenWindow) {
		return blob, payload, nil
	}
	if payload.RefreshToken == "" {
		return "", nil, errNoRefreshToken
	}
	if checkLive && s.Live != nil {
		if live, err := s.Live.Read(ctx); err == nil && live != "" {
			if lp, err := live.Extract(); err == nil && lp.RefreshToken == payload.RefreshToken {
				s.logf("refresh account %d: skipped, token shared with live login", num)
				return "", nil, errSharedWithLive
			}
		}
	}

	fresh, err := s.Refresh.Refresh(ctx, payload.RefreshToken)
	if err != nil {
		s.logf("refresh account %d: failed: %v", num, err)
		return "", nil, err
	}
	if fresh == nil || fresh.AccessToken == "" || fresh.RefreshToken == "" {
		s.logf("refresh account %d: failed: incomplete token", num)
		return "", nil, errIncompleteRefresh
	}
	refreshed, err := blob.WithRefreshed(fresh)
	if err != nil {
		return "", nil, fmt.Errorf("store refreshed backup token: %w", err)
	}
	if refreshed == "" {
		return "", nil, errors.New("store refreshed backup token: empty result")
	}
	// The old refresh token is now revoked server-side: losing this write
	// loses the login, so retry once and log loudly if it still fails.
	if err := s.Backup.Write(ctx, num, email, refreshed); err != nil {
		if err = s.Backup.Write(ctx, num, email, refreshed); err != nil {
			s.logf("refresh account %d: rotated but backup write FAILED: %v", num, err)
			return refreshed, fresh, nil
		}
	}
	s.logf("refresh account %d: ok", num)
	return refreshed, fresh, nil
}

// logf writes to the csw diagnostics log; a nil Log discards.
func (s *Service) logf(format string, args ...any) {
	if s.Log != nil {
		s.Log.Printf(format, args...)
	}
}
