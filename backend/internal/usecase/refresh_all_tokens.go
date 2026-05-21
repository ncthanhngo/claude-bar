package usecase

import (
	"context"
	"fmt"
	"strings"
)

// RefreshAllTokens proactively refreshes the OAuth credentials for every
// inactive account. Called once per day by the widget on startup so that
// backup tokens never go stale between swaps.
//
// The active account is intentionally skipped — Claude Code owns its token
// refresh cycle while it is running.
func (s *Service) RefreshAllTokens(ctx context.Context) error {
	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return err
	}

	var failures []string
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
				failures = append(failures, fmt.Sprintf("account %d (%s): %v", num, acc.Email, refErr))
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
	if len(failures) > 0 {
		return fmt.Errorf("partial refresh failures: %s", strings.Join(failures, "; "))
	}
	return nil
}
