package usecase

import (
	"context"
	"sync"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/oauth"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// VerifyAccounts probes every account in the registry to confirm it can
// actually be swapped to. Checks per account:
//
//   credentials_present  — backup (or live) keychain entry exists
//   credentials_valid    — JSON parses, has access + refresh tokens
//   token_refresh        — refresh_token works (skipped for active account)
//   usage_reachable      — Anthropic usage API accepts the access token
//
// "swap_ready" requires all non-skipped checks to pass.
func (s *Service) VerifyAccounts(ctx context.Context) (*domain.VerificationReport, error) {
	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return nil, err
	}

	results := make([]*domain.AccountVerification, 0, len(reg.Sequence))
	for _, num := range reg.Sequence {
		acc, ok := reg.Accounts[num]
		if !ok {
			continue
		}
		results = append(results, &domain.AccountVerification{
			AccountNum:  num,
			Email:       acc.Email,
			DisplayName: acc.DisplayName(),
			IsActive:    num == reg.ActiveAccountNumber,
		})
	}

	var wg sync.WaitGroup
	for _, r := range results {
		wg.Add(1)
		go func(r *domain.AccountVerification) {
			defer wg.Done()
			s.verifyOne(ctx, r)
		}(r)
	}
	wg.Wait()

	report := &domain.VerificationReport{Results: results, Total: len(results)}
	for _, r := range results {
		if r.SwapReady {
			report.Ready++
		} else {
			report.Failed++
		}
	}
	return report, nil
}

func (s *Service) verifyOne(ctx context.Context, r *domain.AccountVerification) {
	add := func(name string, passed bool, detail string) {
		r.Checks = append(r.Checks, domain.CheckResult{
			Name: name, Passed: passed, Detail: detail,
		})
	}
	addSkip := func(name, reason string) {
		r.Checks = append(r.Checks, domain.CheckResult{
			Name: name, Skipped: true, Detail: reason,
		})
	}

	// 1. credentials_present
	var blob domain.CredentialBlob
	var err error
	if r.IsActive {
		blob, err = s.Live.Read(ctx)
	} else {
		blob, err = s.Backup.Read(ctx, r.AccountNum, r.Email)
	}
	if err != nil {
		add("credentials_present", false, err.Error())
		r.SwapReady = false
		return
	}
	if blob == "" {
		add("credentials_present", false, "keychain entry empty")
		r.SwapReady = false
		return
	}
	add("credentials_present", true, "")

	// 2. credentials_valid
	payload, err := blob.Extract()
	if err != nil {
		add("credentials_valid", false, err.Error())
		r.SwapReady = false
		return
	}
	if payload.AccessToken == "" || payload.RefreshToken == "" {
		add("credentials_valid", false, "missing access or refresh token")
		r.SwapReady = false
		return
	}
	add("credentials_valid", true, "")

	// 3. token_refresh — only for inactive (claude owns active refresh).
	// Mutex serialises refresh+write per account across concurrent verify calls
	// and races with switch/refresh-all on the same account's backup token.
	access := payload.AccessToken
	if r.IsActive {
		addSkip("token_refresh", "active account — claude owns refresh")
	} else {
		var freshAccess string
		var refreshFailed bool
		func() {
			unlock := s.lockBackupRefresh(r.AccountNum)
			defer unlock()
			fresh, refErr := s.Refresh.Refresh(ctx, payload.RefreshToken)
			if refErr != nil || fresh == nil {
				detail := "refresh failed"
				if refErr != nil {
					detail = refErr.Error()
				}
				add("token_refresh", false, detail)
				r.SwapReady = false
				refreshFailed = true
				return
			}
			add("token_refresh", true, "")
			freshAccess = fresh.AccessToken
			if newBlob, err := blob.WithRefreshed(fresh); err == nil && newBlob != "" {
				_ = s.Backup.Write(ctx, r.AccountNum, r.Email, newBlob)
			}
		}()
		if refreshFailed {
			return
		}
		access = freshAccess
	}

	// 4. usage_reachable
	if _, err := s.Usage.Fetch(ctx, access); err != nil {
		// Soft-pass on rate limit: swap doesn't need usage; just warn.
		if _, ok := err.(*oauth.RateLimitedError); ok {
			addSkip("usage_reachable", "rate limited — usage check skipped")
			r.SwapReady = true
			return
		}
		add("usage_reachable", false, err.Error())
		r.SwapReady = false
		return
	}
	add("usage_reachable", true, "")
	r.SwapReady = true
}
