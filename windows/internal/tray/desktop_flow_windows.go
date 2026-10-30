//go:build windows

package tray

import (
	"errors"

	"github.com/ncruces/zenity"

	"github.com/soi/claude-swap-widget/windows/internal/cswclient"
)

// saveDesktopLogin stores Claude Desktop's current sign-in as account num's.
// Desktop is closed for the copy (its files are locked while it runs) and
// reopened if it was running.
func (a *app) saveDesktopLogin(num int) {
	if !a.begin("Save Claude Desktop sign-in") {
		a.post("error", "Wait for “"+a.busyWith()+"” to finish, then try again.")
		return
	}
	defer a.end()
	v, ok := a.account(num)
	if !ok {
		return
	}
	fail := func(err error) {
		logf("desktop save %d: %v", num, err)
		a.post("error", "Claude Desktop sign-in not saved: "+err.Error())
	}
	d, ok := findDesktop()
	if !ok {
		fail(errors.New("Claude Desktop is not installed (or has never been opened)"))
		return
	}
	uuid := d.accountUUID()
	if uuid == "" {
		fail(errors.New("Claude Desktop is not signed in — sign in to " + v.Account.Email + " in Claude Desktop first"))
		return
	}
	key := identityKey(v.Account)
	if other := desktopKeyFor(uuid); other != "" && other != key {
		fail(errors.New("Claude Desktop is signed in to the account already saved as " + a.nameForKey(other) +
			" — sign Desktop out, sign in to " + v.Account.Email + ", then save again"))
		return
	}
	if zenity.Question("Save Claude Desktop's current sign-in as "+v.Account.DisplayName()+" ("+v.Account.Email+")?\n\n"+
		"Make sure Claude Desktop is signed in to that account. Claude Desktop closes for a moment and reopens.",
		zenity.Title(appTitle), zenity.OKLabel("Save")) != nil {
		return
	}
	was := d.running()
	if err := d.quit(); err != nil {
		fail(err)
		return
	}
	blob, err := d.capture()
	if err == nil {
		err = writeDesktopSave(v.Account, blob)
	}
	if was {
		_ = d.launch()
	}
	if err != nil {
		fail(err)
		return
	}
	setDesktopIndex(key, uuid)
	logf("desktop save %d: ok", num)
	a.post("ok", "Saved Claude Desktop’s sign-in for "+v.Account.DisplayName()+
		". To add another account, use ⋯ → Sign Claude Desktop in to another account — not Log out in Desktop, which ends the saved session.")
}

// desktopSignInAnother gets Claude Desktop to its sign-in screen for the
// next account without logging the current one out: Desktop's "Log out"
// ends the session at Anthropic, which would make the saved copy useless.
// The current sign-in must be saved first, or it would simply be lost.
func (a *app) desktopSignInAnother() {
	if !a.begin("Sign Claude Desktop in to another account") {
		a.post("error", "Wait for “"+a.busyWith()+"” to finish, then try again.")
		return
	}
	defer a.end()
	fail := func(err error) {
		logf("desktop sign in another: %v", err)
		a.post("error", "Claude Desktop not changed: "+err.Error())
	}
	d, ok := findDesktop()
	if !ok {
		fail(errors.New("Claude Desktop is not installed (or has never been opened)"))
		return
	}
	if uuid := d.accountUUID(); uuid != "" {
		key := desktopKeyFor(uuid)
		if key == "" {
			fail(errors.New("save Claude Desktop’s current sign-in first (⋯ on that account’s row → Save Claude Desktop sign-in here), or it would be lost"))
			return
		}
		// Refresh the save so it holds the newest session.
		if err := d.quit(); err != nil {
			fail(err)
			return
		}
		for _, v := range a.snapshotAccounts() {
			if identityKey(v.Account) == key {
				if blob, err := d.capture(); err == nil {
					_ = writeDesktopSave(v.Account, blob)
				}
			}
		}
	} else if err := d.quit(); err != nil {
		fail(err)
		return
	}
	if err := d.forgetSignIn(); err != nil {
		fail(err)
		return
	}
	_ = d.launch()
	logf("desktop sign in another: ready")
	a.post("ok", "Claude Desktop is at its sign-in screen. Sign in to the next account there, then ⋯ on that account’s row → Save Claude Desktop sign-in here.")
}

// snapshotAccounts copies the account list.
func (a *app) snapshotAccounts() []cswclient.AccountView {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]cswclient.AccountView(nil), a.accounts...)
}

// nameForKey is the display name of the account with identity key key.
func (a *app) nameForKey(key string) string {
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, v := range a.accounts {
		if identityKey(v.Account) == key {
			return v.Account.DisplayName()
		}
	}
	return "another account"
}

// switchDesktop moves Claude Desktop to target's saved sign-in, keeping the
// outgoing account's (possibly renewed) session first. Returns a sentence
// for the switch notice ("" when Desktop is not involved).
func (a *app) switchDesktop(target cswclient.Account) string {
	a.mu.Lock()
	on := a.settings.SwitchDesktop
	accounts := append([]cswclient.AccountView(nil), a.accounts...)
	a.mu.Unlock()
	d, found := findDesktop()
	if !on || !found {
		return ""
	}
	key := identityKey(target)
	if !hasDesktopSave(target) {
		logf("desktop switch to %d: no saved Desktop sign-in", target.Number)
		return " Claude Desktop was not switched: no Desktop sign-in saved for " + target.DisplayName() +
			" yet (sign Desktop in to it, then ⋯ on its row → Save Claude Desktop sign-in here)."
	}
	current := d.accountUUID()
	if current != "" && desktopIndex()[key] == current {
		return "" // already there
	}
	// Desktop's own account id says whose session is in it now; only then
	// is it safe to refresh that account's save before replacing it.
	ownerKey := desktopKeyFor(current)

	was := d.running()
	if err := d.quit(); err != nil {
		logf("desktop switch: %v", err)
		return " Claude Desktop was not switched: " + err.Error() + "."
	}
	for _, v := range accounts {
		if ownerKey != "" && identityKey(v.Account) == ownerKey {
			if blob, err := d.capture(); err == nil {
				_ = writeDesktopSave(v.Account, blob)
			}
		}
	}
	blob, err := readDesktopSave(target)
	if err == nil {
		err = d.restore(blob)
	}
	if err != nil {
		logf("desktop switch to %d: %v", target.Number, err)
		if was {
			_ = d.launch()
		}
		return " Claude Desktop was not switched: " + err.Error() + "."
	}
	logf("desktop switch to %d: ok (relaunch=%v)", target.Number, was)
	if was {
		_ = d.launch()
		return " Claude Desktop restarted as " + target.DisplayName() + "."
	}
	return " Claude Desktop will open as " + target.DisplayName() + "."
}

func (a *app) toggleSwitchDesktop() {
	a.mu.Lock()
	a.settings.SwitchDesktop = !a.settings.SwitchDesktop
	s := a.settings
	a.mu.Unlock()
	if err := saveSettings(s); err != nil {
		logf("save settings: %v", err)
	}
	a.pushState()
}
