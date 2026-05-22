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
	if s.UsageCache != nil {
		if entry, fresh := s.UsageCache.Get(v.Account.Number); fresh && entry != nil {
			v.Usage = entry.Usage
			return
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
func (s *Service) fallbackToCache(v *AccountView, err error) {
	if s.UsageCache != nil {
		if entry, _ := s.UsageCache.Get(v.Account.Number); entry != nil && entry.Usage != nil {
			v.Usage = entry.Usage
			return
		}
	}
	v.Error = err.Error()
}
