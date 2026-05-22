package usecase

import (
	"context"
	"errors"
	"sync"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/oauth"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// VerifyAccounts probes every account in the registry to confirm it can
// actually be swapped to. Checks per account:
//
//   credentials_present  — backup (or live) keychain entry exists
//   credentials_valid    — JSON parses, has access + refresh tokens
//   token_refresh        — only forced when access token is expired, OR when
//                          usage_reachable returns 401 with a still-valid
//                          access timestamp (active account is exempt).
//   usage_reachable      — Anthropic usage API accepts the access token
//
// "swap_ready" requires all non-skipped checks to pass. The token_refresh
// stage is deliberately lazy so a routine health check does not rotate
// refresh tokens that are still healthy — every rotation is a real
// side-effect (server-side invalidation + Keychain write race window) and
// is reserved for the explicit "Refresh credentials" action / RefreshAllTokens.
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
	// setCheck replaces an existing check by name, or appends if absent.
	// Used when the lazy path skips token_refresh and a later usage 401 forces
	// a real rotation — the original "skipped" row is rewritten with the real
	// outcome so the report stays internally consistent.
	setCheck := func(c domain.CheckResult) {
		for i := range r.Checks {
			if r.Checks[i].Name == c.Name {
				r.Checks[i] = c
				return
			}
		}
		r.Checks = append(r.Checks, c)
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

	// 3. token_refresh — lazy.
	//   active: skip; claude owns the live refresh cycle.
	//   inactive + access still valid: skip rotation, fall through to usage.
	//   inactive + access expired: rotate now; rate-limited is treated as skip
	//     (transient), hard failure is treated as not swap-ready.
	access := payload.AccessToken
	canRotateOn401 := false
	switch {
	case r.IsActive:
		addSkip("token_refresh", "active account — claude owns refresh")
	case !oauth.IsExpired(payload.ExpiresAt):
		addSkip("token_refresh", "access token still valid")
		canRotateOn401 = true
	default:
		fresh, rotErr := s.rotateBackup(ctx, r, blob, payload, setCheck)
		if rotErr != nil {
			// Hard failure path already recorded the failed token_refresh row
			// and set SwapReady=false. Rate-limited path recorded a skip;
			// usage with the expired access will almost certainly fail, but
			// we still attempt it so the report surfaces the underlying state.
			if _, isRL := rotErr.(*oauth.RateLimitedError); !isRL {
				return
			}
			// Token still expired; don't try a second rotation on usage 401.
		} else {
			access = fresh
		}
	}

	// 4. usage_reachable — try with current access; on 401 from a still-valid
	// inactive token, rotate once and retry (covers the rare case where the
	// access token was revoked server-side before its stated expiry).
	// We only care about the error — usage payload is consumed by ListAccounts,
	// not here.
	_, err = s.Usage.Fetch(ctx, access)
	if err != nil {
		if _, isUnauthorized := err.(*oauth.UnauthorizedError); isUnauthorized && canRotateOn401 {
			fresh, rotErr := s.rotateBackup(ctx, r, blob, payload, setCheck)
			if rotErr == nil {
				access = fresh
				_, err = s.Usage.Fetch(ctx, access)
			}
			// rotErr != nil: leave the original UnauthorizedError as `err` so
			// usage_reachable below records the honest failure.
		}
	}
	if err != nil {
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

// rotateBackup performs an OAuth refresh for an inactive account under the
// per-account mutex, writes the refreshed blob to Keychain backup, and records
// the outcome via setCheck. Returns (newAccessToken, nil) on success.
// On rate limit returns ("", *oauth.RateLimitedError) and records token_refresh
// as skipped (transient). On any other failure returns ("", err) with
// token_refresh recorded as failed and r.SwapReady set to false.
func (s *Service) rotateBackup(
	ctx context.Context,
	r *domain.AccountVerification,
	blob domain.CredentialBlob,
	payload *domain.OAuthPayload,
	setCheck func(domain.CheckResult),
) (string, error) {
	var newAccess string
	var outErr error

	func() {
		unlock := s.lockBackupRefresh(r.AccountNum)
		defer unlock()

		fresh, refErr := s.Refresh.Refresh(ctx, payload.RefreshToken)
		if refErr != nil {
			if rl, ok := refErr.(*oauth.RateLimitedError); ok {
				setCheck(domain.CheckResult{
					Name:    "token_refresh",
					Skipped: true,
					Detail:  "rate limited — " + rl.Error(),
				})
				outErr = refErr
				return
			}
			setCheck(domain.CheckResult{Name: "token_refresh", Passed: false, Detail: refErr.Error()})
			r.SwapReady = false
			outErr = refErr
			return
		}
		if fresh == nil {
			setCheck(domain.CheckResult{Name: "token_refresh", Passed: false, Detail: "refresh returned nil payload"})
			r.SwapReady = false
			outErr = errors.New("refresh returned nil payload")
			return
		}
		setCheck(domain.CheckResult{Name: "token_refresh", Passed: true})
		newAccess = fresh.AccessToken
		if newBlob, err := blob.WithRefreshed(fresh); err == nil && newBlob != "" {
			_ = s.Backup.Write(ctx, r.AccountNum, r.Email, newBlob)
		}
	}()

	return newAccess, outErr
}
