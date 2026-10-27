//go:build windows

package tray

import (
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
	d, ok := findDesktop()
	if !ok {
		_ = zenity.Info("Claude Desktop is not installed (or has never been opened).", zenity.Title(appTitle))
		return
	}
	if zenity.Question("Save Claude Desktop's current sign-in as "+v.Account.DisplayName()+" ("+v.Account.Email+")?\n\n"+
		"Make sure Claude Desktop is signed in to that account. Claude Desktop closes for a moment and reopens.",
		zenity.Title(appTitle), zenity.OKLabel("Save")) != nil {
		return
	}
	was := d.running()
	if err := d.quit(); err != nil {
		showError("Could not close Claude Desktop", err)
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
		logf("desktop save %d: %v", num, err)
		showError("Could not save the Claude Desktop sign-in", err)
		return
	}
	setDesktopOwner(identityKey(v.Account))
	logf("desktop save %d: ok", num)
	a.post("ok", "Saved Claude Desktop’s sign-in for "+v.Account.DisplayName()+". Switching to it now switches Claude Desktop too.")
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
	owner := desktopOwner()
	if !hasDesktopSave(target) {
		logf("desktop switch to %d: no saved Desktop sign-in", target.Number)
		return " Claude Desktop was not switched: no Desktop sign-in saved for " + target.DisplayName() +
			" yet (sign Desktop in to it, then ⋯ on its row → Save Claude Desktop sign-in here)."
	}
	if owner == key {
		return ""
	}
	was := d.running()
	if err := d.quit(); err != nil {
		logf("desktop switch: %v", err)
		return " Claude Desktop was not switched: " + err.Error() + "."
	}
	// Keep the outgoing account's session up to date (claude.ai renews it).
	for _, v := range accounts {
		if owner != "" && identityKey(v.Account) == owner {
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
	setDesktopOwner(key)
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
