package usecase

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/oauth"
)

// RefreshAllError carries the per-account outcome of RefreshAllTokens so
// callers can decide which bucket of failures should abort their flow.
//
//   - HardFailures: network / 5xx — actually transient, blocks cloud push.
//   - RateLimited: 429 — caller may proceed and retry later.
//   - NeedsRelogin: 400 invalid_grant — permanent per-account; user must
//     re-login that account. Does NOT block a cloud push because the
//     remaining accounts (and their MCP connectors) are still pushable
//     and the broken account's last-known blob is preserved on the
//     remote so re-login on another device can still recover.
type RefreshAllError struct {
	HardFailures []string
	RateLimited  []string
	NeedsRelogin []string
}

func (e *RefreshAllError) Error() string {
	var parts []string
	if len(e.HardFailures) > 0 {
		parts = append(parts, "partial refresh failures: "+strings.Join(e.HardFailures, "; "))
	}
	if len(e.NeedsRelogin) > 0 {
		parts = append(parts, "needs re-login: "+strings.Join(e.NeedsRelogin, "; "))
	}
	if len(e.RateLimited) > 0 {
		parts = append(parts, "rate limited: "+strings.Join(e.RateLimited, "; "))
	}
	return strings.Join(parts, "; ")
}

// BlocksPush reports whether the failures should abort a cloud push.
// Only true when at least one account hit a real transient/unknown error.
// Rate-limited (429) and needs-relogin (invalid_grant) are softer states
// that the caller may choose to skip past — push the rest of the bundle
// rather than withholding everything on one bad token.
func (e *RefreshAllError) BlocksPush() bool {
	return len(e.HardFailures) > 0
}

// RefreshAllTokens proactively refreshes the OAuth credentials for every
// inactive account. Called once per day by the widget on startup so that
// backup tokens never go stale between swaps.
//
// The active account is intentionally skipped — Claude Code owns its token
// refresh cycle while it is running.
//
// On any per-account failure the returned error is a *RefreshAllError so
// callers can branch on HardFailures vs NeedsRelogin vs RateLimited via
// errors.As. A flat error message is still produced for legacy callers
// that only inspect Error().
func (s *Service) RefreshAllTokens(ctx context.Context) error {
	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return err
	}

	var hardFailures, rateLimited, needsRelogin []string
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
				label := fmt.Sprintf("account %d (%s): %v", num, acc.Email, refErr)
				switch {
				case isRateLimited(refErr):
					rateLimited = append(rateLimited, label)
				case isInvalidGrant(refErr):
					needsRelogin = append(needsRelogin, label)
				default:
					hardFailures = append(hardFailures, label)
				}
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
	if len(hardFailures) == 0 && len(rateLimited) == 0 && len(needsRelogin) == 0 {
		return nil
	}
	return &RefreshAllError{
		HardFailures: hardFailures,
		RateLimited:  rateLimited,
		NeedsRelogin: needsRelogin,
	}
}

func isRateLimited(err error) bool {
	var rl *oauth.RateLimitedError
	return errors.As(err, &rl)
}

// isInvalidGrant matches the Anthropic OAuth response for revoked or
// rotated refresh tokens: HTTP 400 with body containing "invalid_grant".
// Treated as permanent per-account; user must re-login that account.
func isInvalidGrant(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "invalid_grant") ||
		strings.Contains(msg, "oauth refresh 400") ||
		strings.Contains(msg, "oauth refresh 401")
}
