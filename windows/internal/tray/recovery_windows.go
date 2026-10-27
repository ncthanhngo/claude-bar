//go:build windows

package tray

import (
	"context"
	"errors"
	"time"

	"github.com/soi/claude-swap-widget/windows/internal/cswclient"
)

// Background re-login of inactive accounts whose saved login stopped
// working, using the account's claude.ai session in its WebView2 profile.
// Same limits as macOS's CredentialRecoveryCoordinator.
const (
	recoveryMaxAttempts = 3
	recoveryCooldown    = 5 * time.Minute
	recoveryMaxGrants   = 5 // unattended grants per account per hour
	recoveryGrantWindow = time.Hour
)

// recoveryStatus is one account's background re-login bookkeeping.
type recoveryStatus struct {
	attempts      int
	cooldownUntil time.Time
	manual        bool // only the user can fix it: session gone or retries used up
	grants        []time.Time
}

// recoverIfNeeded re-logs-in, one at a time, every inactive account flagged
// as needing login that has a saved claude.ai session and is eligible.
func (a *app) recoverIfNeeded() {
	a.mu.Lock()
	if a.recovering != 0 {
		a.mu.Unlock()
		return
	}
	var targets []cswclient.Account
	for _, v := range a.accounts {
		num := v.Account.Number
		if v.IsActive || !a.needLogin[num] || !hasProfile(v.Account) || !a.recoveryEligible(num) {
			continue
		}
		targets = append(targets, v.Account)
	}
	a.mu.Unlock()

	for _, acc := range targets {
		a.recoverOne(acc)
	}
}

// recoveryEligible: not given up on, past cooldown, under the grant
// budget. Caller holds a.mu.
func (a *app) recoveryEligible(num int) bool {
	st := a.recovery[num]
	if st == nil {
		return true
	}
	if st.manual || time.Now().Before(st.cooldownUntil) || st.attempts >= recoveryMaxAttempts {
		return false
	}
	recent := st.grants[:0]
	for _, g := range st.grants {
		if time.Since(g) < recoveryGrantWindow {
			recent = append(recent, g)
		}
	}
	st.grants = recent
	return len(recent) < recoveryMaxGrants
}

func (a *app) recoverOne(acc cswclient.Account) {
	num := acc.Number
	a.mu.Lock()
	if a.recovering != 0 {
		a.mu.Unlock()
		return
	}
	a.recovering = num
	st := a.recovery[num]
	if st == nil {
		st = &recoveryStatus{}
		a.recovery[num] = st
	}
	st.attempts++
	st.grants = append(st.grants, time.Now())
	a.mu.Unlock()
	a.pushState()

	err := a.backgroundSignIn(acc)

	a.mu.Lock()
	a.recovering = 0
	switch {
	case err == nil:
		delete(a.recovery, num)
		delete(a.needLogin, num)
	case errors.Is(err, errNeedsSignIn), st.attempts >= recoveryMaxAttempts:
		st.manual = true
	default:
		st.cooldownUntil = time.Now().Add(recoveryCooldown)
	}
	a.mu.Unlock()

	if err == nil {
		a.post("ok", "Signed "+acc.DisplayName()+" back in automatically.")
	}
	a.redraw()
}

// backgroundSignIn runs the hidden sign-in with the account's profile and
// saves the result only if it really is that account.
func (a *app) backgroundSignIn(acc cswclient.Account) error {
	ctx := context.Background()
	s, err := a.csw.StartSignIn(ctx)
	if err != nil {
		return err
	}
	code, err := signInWindow(signInOpts{URL: s.URL, Profile: profileFor(acc), Headless: true})
	if err != nil {
		return err
	}
	_, err = a.csw.AddSignedIn(ctx, s, code, "", acc.Email)
	return err
}

// clearRecovery forgets an account's recovery state (after a manual
// sign-in or a remove).
func (a *app) clearRecovery(num int) {
	a.mu.Lock()
	delete(a.recovery, num)
	a.mu.Unlock()
}
