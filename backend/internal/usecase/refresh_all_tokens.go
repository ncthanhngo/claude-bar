package usecase

import (
	"context"
	"fmt"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/oauth"
)

// RefreshAllTokens proactively refreshes the OAuth credentials for every
// inactive account. Called once per day by the widget on startup so that
// backup tokens never go stale between swaps.
//
// The active account is intentionally skipped — Claude Code owns its token
// refresh cycle while it is running.
//
// Rate-limited responses from the OAuth endpoint are surfaced separately
// from hard failures: the returned error string prefixes them with
// "rate limited" so the UI can render them as a transient warning instead
// of a "creds broken" error.
func (s *Service) RefreshAllTokens(ctx context.Context) error {
	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return err
	}

	var hardFailures []string
	var rateLimited []string
	for num, acc := range reg.Accounts {
		if num == reg.ActiveAccountNumber {
			continue
		}
		blob, err := s.Backup.Read(ctx, acc.Number, acc.Email)
		if err != nil || blob == "" {
			continue
		}
		payload, err := blob.Extract()
		if err != nil || payload.RefreshToken == "" {
			continue
		}
		// Mutex serialises with switch/list/verify refresh writers on same account.
		func() {
			unlock := s.lockBackupRefresh(acc.Number)
			defer unlock()
			fresh, refErr := s.Refresh.Refresh(ctx, payload.RefreshToken)
			if refErr != nil {
				if _, isRL := refErr.(*oauth.RateLimitedError); isRL {
					rateLimited = append(rateLimited, fmt.Sprintf("account %d (%s): %v", num, acc.Email, refErr))
					return
				}
				hardFailures = append(hardFailures, fmt.Sprintf("account %d (%s): %v", num, acc.Email, refErr))
				return
			}
			if fresh == nil {
				return
			}
			refreshed, mergeErr := blob.WithRefreshed(fresh)
			if mergeErr != nil || refreshed == "" {
				return
			}
			_ = s.Backup.Write(ctx, acc.Number, acc.Email, refreshed)
		}()
	}
	switch {
	case len(hardFailures) > 0 && len(rateLimited) > 0:
		return fmt.Errorf("partial refresh failures: %s; rate limited: %s",
			strings.Join(hardFailures, "; "), strings.Join(rateLimited, "; "))
	case len(hardFailures) > 0:
		return fmt.Errorf("partial refresh failures: %s", strings.Join(hardFailures, "; "))
	case len(rateLimited) > 0:
		return fmt.Errorf("rate limited: %s", strings.Join(rateLimited, "; "))
	}
	return nil
}
