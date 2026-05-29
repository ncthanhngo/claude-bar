package usecase

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/oauth"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// AccountView is one row in the UI list.
type AccountView struct {
	Account          *domain.Account `json:"account"`
	IsActive         bool            `json:"isActive"`
	Usage            *domain.Usage   `json:"usage,omitempty"`
	Error            string          `json:"error,omitempty"`
	CredentialState  string          `json:"credentialState,omitempty"`
	CredentialError  string          `json:"credentialError,omitempty"`
	SubscriptionType string          `json:"subscriptionType,omitempty"`
}

// ListAccountsResult is what the UI consumes.
type ListAccountsResult struct {
	Accounts            []*AccountView `json:"accounts"`
	ActiveAccountNumber int            `json:"activeAccountNumber"`
}

// ListAccounts returns every account with usage. Usage is fetched in parallel.
// Usage reads the Claude Bar backup credentials for every account, including
// the active account, so polling never touches Claude Code's live Keychain item.
func (s *Service) ListAccounts(ctx context.Context) (*ListAccountsResult, error) {
	return s.listAccounts(ctx, map[int]bool{})
}

// ListAccountsMetadata returns account identity and active-state only.
// The widget uses it when web usage already has the active quota so a menu
// refresh does not also call the OAuth usage endpoint.
func (s *Service) ListAccountsMetadata(ctx context.Context) (*ListAccountsResult, error) {
	return s.listAccounts(ctx, nil)
}

// ListAccountsUsageFor returns account rows while fetching usage only for the
// requested registry numbers. Web-first clients use it for fallback accounts.
func (s *Service) ListAccountsUsageFor(ctx context.Context, accountNumbers map[int]bool) (*ListAccountsResult, error) {
	return s.listAccounts(ctx, accountNumbers)
}

func (s *Service) listAccounts(ctx context.Context, usageAccounts map[int]bool) (*ListAccountsResult, error) {
	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return nil, err
	}

	activeNum := reg.ActiveAccountNumber
	if s.Config != nil {
		if cfg, cfgErr := s.Config.Read(ctx); cfgErr == nil {
			activeNum = activeAccountNumber(reg, cfg)
		}
	}

	views := make([]*AccountView, 0, len(reg.Sequence))
	for _, num := range reg.Sequence {
		acc, ok := reg.Accounts[num]
		if !ok {
			continue
		}
		views = append(views, &AccountView{
			Account:  acc,
			IsActive: num == activeNum,
		})
	}

	if usageAccounts != nil {
		if len(usageAccounts) == 0 {
			usageAccounts = allUsageAccounts(views)
		}
		var wg sync.WaitGroup
		for _, v := range views {
			if !usageAccounts[v.Account.Number] {
				continue
			}
			wg.Add(1)
			go func(v *AccountView) {
				defer wg.Done()
				s.fillUsage(ctx, v)
			}(v)
		}
		wg.Wait()
	}

	// Inspect the LIVE credential for the active account. Runs on every call
	// (including metadata-only) so credential loss is surfaced even when the
	// usage fetch is skipped. Runs AFTER fillUsage so a definitive needs_login
	// from the live check always wins over a stale fillUsage result.
	for _, v := range views {
		if v.IsActive {
			s.inspectActiveCredential(ctx, v)
			break
		}
	}

	return &ListAccountsResult{
		Accounts:            views,
		ActiveAccountNumber: activeNum,
	}, nil
}

func allUsageAccounts(views []*AccountView) map[int]bool {
	accountNumbers := make(map[int]bool, len(views))
	for _, v := range views {
		accountNumbers[v.Account.Number] = true
	}
	return accountNumbers
}

// inspectActiveCredential performs a READ-ONLY liveness check of the LIVE
// credential slot (the token Claude Code itself uses). It only sets
// CredentialState/CredentialError when it finds a definitive failure; it never
// clears a healthy state set by fillUsage.
//
// Safety invariants upheld here:
//   - NEVER calls Refresh on the live token. The live refresh_token is
//     single-use-rotating; refreshing it from here would desync Claude Code.
//   - NEVER writes or deletes the live credential.
//   - On ANY ambiguity (read error, network error, 429, expired-but-maybe-ok)
//     the view is left unchanged. False-positive "needs_login" on an active
//     session is worse than a missed detection.
func (s *Service) inspectActiveCredential(ctx context.Context, v *AccountView) {
	if s.Live == nil {
		return
	}

	blob, err := s.Live.Read(ctx)
	if err != nil {
		// Read failure is ambiguous (Keychain ACL, timeout, etc.) — leave as-is.
		return
	}
	if blob == "" {
		// Empty slot = logged out; this is definitive.
		v.CredentialState = "needs_login"
		v.CredentialError = "not logged in (live credential missing)"
		return
	}

	payload, err := blob.Extract()
	if err != nil {
		// Corrupt/unreadable blob — definitive; Claude Code can't use it either.
		v.CredentialState = "needs_login"
		v.CredentialError = "live credential unreadable: " + err.Error()
		return
	}

	if payload.AccessToken == "" || payload.RefreshToken == "" {
		v.CredentialState = "needs_login"
		v.CredentialError = "live credential missing tokens"
		return
	}

	// Access token is NOT expired: probe liveness with a read-only usage call.
	// A 401 on a non-expired token is unambiguously revoked.
	// Expired tokens are left alone — Claude Code will rotate them; we cannot
	// classify expiry without refreshing, and refreshing is forbidden here.
	if !oauth.IsExpired(payload.ExpiresAt) {
		if s.Usage == nil {
			return
		}
		// Don't probe while a rate-limit backoff is active — the endpoint is
		// already throttling us, and a 429 here tells us nothing about the
		// token's validity. Skip and re-check on a later poll.
		if s.Backoff != nil {
			if skip, _ := s.Backoff.ShouldSkip(); skip {
				return
			}
		}
		_, fetchErr := s.Usage.Fetch(ctx, payload.AccessToken)
		if fetchErr != nil {
			if oauth.IsDefinitiveAuthFailure(fetchErr) {
				// 401 on a non-expired token = token revoked server-side.
				v.CredentialState = "needs_login"
				v.CredentialError = "live token rejected (401)"
			}
			// RateLimitedError, network error, or other transient → leave as-is.
			return
		}
		// Probe succeeded: the live token is definitively healthy. Emit a
		// positive "ready" so a stale "needs_login" from an earlier poll does
		// not stick. The widget merges snapshots with `credentialState ??
		// previous.credentialState`, so without this explicit healthy signal a
		// recovered active credential would remain flagged needs_login forever.
		v.CredentialState = "ready"
		v.CredentialError = ""
	}
	// Expired token → no action; leave CredentialState unchanged.
}

func (s *Service) fillUsage(ctx context.Context, v *AccountView) {
	blob, err := s.Backup.Read(ctx, v.Account.Number, v.Account.Email)
	if err != nil {
		s.fallbackToCache(v, err)
		return
	}
	if blob == "" {
		v.Error = "no credentials"
		if !v.IsActive {
			v.CredentialState = "needs_login"
			v.CredentialError = "backup credentials missing"
		}
		return
	}
	payload, err := blob.Extract()
	if err != nil {
		if !v.IsActive {
			v.CredentialState = "needs_login"
			v.CredentialError = err.Error()
		}
		s.fallbackToCache(v, err)
		return
	}
	v.CredentialState = "ready"
	if !v.IsActive && (payload.AccessToken == "" || payload.RefreshToken == "") {
		v.CredentialState = "needs_login"
		v.CredentialError = "backup is missing access or refresh token"
	}
	v.SubscriptionType = payload.SubscriptionType
	access := payload.AccessToken

	// Token expired -> refresh only the backup copy. Claude Code still owns the
	// live active credential; this avoids keychain prompts during menu polling.
	// Mutex serialises this per-account so concurrent callers don't race on
	// the same refresh token when the provider rotates on first use.
	if payload.RefreshToken != "" && oauth.IsExpired(payload.ExpiresAt) {
		var freshAccess, credErr string
		func() {
			unlock := s.lockBackupRefresh(v.Account.Number)
			defer unlock()
			fresh, refErr := s.Refresh.Refresh(ctx, payload.RefreshToken)
			if refErr != nil || fresh == nil || fresh.AccessToken == "" || fresh.RefreshToken == "" {
				credErr = refreshFailureDetail(refErr, fresh)
				return
			}
			if newBlob, blobErr := blob.WithRefreshed(fresh); blobErr == nil && newBlob != "" {
				_ = s.Backup.Write(ctx, v.Account.Number, v.Account.Email, newBlob)
			}
			freshAccess = fresh.AccessToken
		}()
		if credErr != "" && !v.IsActive {
			v.CredentialState = "needs_login"
			v.CredentialError = credErr
		} else if freshAccess != "" {
			access = freshAccess
		}
	}

	// Fresh usage cache still short-circuits the API call, but credential
	// inspection above runs every poll so stale backups surface promptly.
	// Skip the short-circuit when the cached resetsAt has already passed:
	// the quota window has rolled over, so the cached utilization% no longer
	// reflects reality and we want a live API call to pick up the new window.
	if s.UsageCache != nil {
		if entry, fresh := s.UsageCache.Get(v.Account.Number); fresh && entry != nil {
			if !entry.Usage.HasPastResetWindow(time.Now()) {
				v.Usage = entry.Usage
				return
			}
		}
	}

	// Backoff in effect -> serve stale cache + cooldown message, skip API.
	if s.Backoff != nil {
		if skip, remaining := s.Backoff.ShouldSkip(); skip {
			if s.UsageCache != nil {
				if entry, _ := s.UsageCache.Get(v.Account.Number); entry != nil && entry.Usage != nil {
					v.Usage = entry.Usage
					return
				}
			}
			v.Error = fmt.Sprintf("rate limited — retry in %s", shortDuration(remaining))
			return
		}
	}

	usage, err := s.Usage.Fetch(ctx, access)
	if err != nil {
		if _, ok := err.(*oauth.RateLimitedError); ok && s.Backoff != nil {
			s.Backoff.RecordRateLimit()
		}
		s.fallbackToCache(v, err)
		return
	}
	if s.Backoff != nil {
		s.Backoff.RecordSuccess()
	}
	v.Usage = usage
	if s.UsageCache != nil {
		_ = s.UsageCache.Put(v.Account.Number, usage)
	}
}

func refreshFailureDetail(err error, fresh *domain.OAuthPayload) string {
	if err != nil {
		return err.Error()
	}
	if fresh == nil {
		return "refresh returned no token"
	}
	return "refresh returned incomplete token"
}

func shortDuration(d time.Duration) string {
	if d <= 0 {
		return "now"
	}
	m := int(d.Minutes())
	s := int(d.Seconds()) % 60
	if m == 0 {
		return fmt.Sprintf("%ds", s)
	}
	if m < 60 {
		return fmt.Sprintf("%dm %02ds", m, s)
	}
	h := m / 60
	return fmt.Sprintf("%dh %02dm", h, m%60)
}

// fallbackToCache prefers showing stale data over an error message. The UI
// can still surface "stale" via the FetchedAt timestamp.
//
// When the cached usage references a quota window that has already rolled
// over, also propagate the fetch error so the UI shows a "couldn't refresh"
// badge alongside the stale numbers — otherwise a broken backup token would
// silently freeze the row at the pre-reset utilization% forever.
func (s *Service) fallbackToCache(v *AccountView, err error) {
	if s.UsageCache != nil {
		if entry, _ := s.UsageCache.Get(v.Account.Number); entry != nil && entry.Usage != nil {
			v.Usage = entry.Usage
			if entry.Usage.HasPastResetWindow(time.Now()) {
				v.Error = err.Error()
			}
			return
		}
	}
	v.Error = err.Error()
}
