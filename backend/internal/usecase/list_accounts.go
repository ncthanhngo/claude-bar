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
	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return nil, err
	}

	views := make([]*AccountView, 0, len(reg.Sequence))
	for _, num := range reg.Sequence {
		acc, ok := reg.Accounts[num]
		if !ok {
			continue
		}
		views = append(views, &AccountView{
			Account:  acc,
			IsActive: num == reg.ActiveAccountNumber,
		})
	}

	var wg sync.WaitGroup
	for _, v := range views {
		wg.Add(1)
		go func(v *AccountView) {
			defer wg.Done()
			s.fillUsage(ctx, v)
		}(v)
	}
	wg.Wait()

	return &ListAccountsResult{
		Accounts:            views,
		ActiveAccountNumber: reg.ActiveAccountNumber,
	}, nil
}

func (s *Service) fillUsage(ctx context.Context, v *AccountView) {
	// 1. Fresh cache hit -> done.
	if s.UsageCache != nil {
		if entry, fresh := s.UsageCache.Get(v.Account.Number); fresh && entry != nil {
			v.Usage = entry.Usage
			return
		}
	}

	// 2. Backoff in effect -> serve stale cache + cooldown message, skip API.
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

	blob, err := s.Backup.Read(ctx, v.Account.Number, v.Account.Email)
	if err != nil {
		s.fallbackToCache(v, err)
		return
	}
	if blob == "" {
		v.Error = "no credentials"
		return
	}
	payload, err := blob.Extract()
	if err != nil {
		s.fallbackToCache(v, err)
		return
	}
	v.SubscriptionType = payload.SubscriptionType
	access := payload.AccessToken

	// Token expired -> refresh only the backup copy. Claude Code still owns the
	// live active credential; this avoids keychain prompts during menu polling.
	if payload.RefreshToken != "" && oauth.IsExpired(payload.ExpiresAt) {
		fresh, refErr := s.Refresh.Refresh(ctx, payload.RefreshToken)
		if refErr == nil && fresh != nil {
			newBlob, _ := blob.WithRefreshed(fresh)
			if newBlob != "" {
				_ = s.Backup.Write(ctx, v.Account.Number, v.Account.Email, newBlob)
				access = fresh.AccessToken
			}
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
