//go:build windows

// Package tray is the notification-area menu: list accounts, switch, add,
// rename, remove.
package tray

import (
	"context"
	_ "embed"
	"errors"
	"fmt"
	"os"
	"sync"
	"time"

	"fyne.io/systray"
	"github.com/ncruces/zenity"

	"github.com/soi/claude-swap-widget/windows/internal/cswclient"
	"github.com/soi/claude-swap-widget/windows/internal/winutil"
)

//go:embed icon.ico
var icon []byte

const (
	appTitle       = "Claude Swap"
	maxAccounts    = 12
	refreshEvery = 5 * time.Minute
	verifyEvery  = 6 * time.Hour
	// snapshotEvery saves Claude Code's rotated login of the active account.
	snapshotEvery = 15 * time.Minute
	// listTimeout bounds the read-only list. Other csw commands are never
	// killed: a kill between a token refresh and its save loses the login.
	listTimeout = 30 * time.Second
	releasesURL = "https://github.com/ncthanhngo/claude-bar/releases?q=win-v&expanded=true" // Windows releases only
)

// Version is stamped at build time.
var Version = "dev"

type app struct {
	csw *cswclient.Client

	mu        sync.Mutex
	busy      string // the operation in flight, "" when idle
	accounts  []cswclient.AccountView
	needLogin map[int]bool
	status    string // the header line, shown in menu and popover

	// Popover-only state. Usage is kept apart from accounts because the
	// periodic metadata-only list carries none.
	pop          *popover
	usage        map[int]*cswclient.Usage
	usageAt      time.Time
	loadingUsage bool
	swapping     int
	loadErr      string
	notice       *notice

	// Background re-login (recovery_windows.go).
	recovering int
	recovery   map[int]*recoveryStatus

	header    *systray.MenuItem
	slots     []*systray.MenuItem
	slotNums  []int
	signIn    *systray.MenuItem
	add       *systray.MenuItem
	rename    *systray.MenuItem
	remove    *systray.MenuItem
	autostart *systray.MenuItem
	reloadIDE *systray.MenuItem
	settings  settings
}

// Run blocks until the user quits.
func Run(csw *cswclient.Client) {
	a := &app{csw: csw, needLogin: map[int]bool{}, usage: map[int]*cswclient.Usage{},
		recovery: map[int]*recoveryStatus{}, settings: loadSettings()}
	systray.Run(a.onReady, func() {})
}

func (a *app) onReady() {
	systray.SetIcon(icon)
	systray.SetTitle(appTitle)
	systray.SetTooltip(appTitle)
	// Left click opens the popover (like the macOS menu-bar popover); right
	// click keeps the classic menu.
	a.pop = newPopover(a.onPopoverAction)
	systray.SetOnTapped(a.pop.Toggle)

	a.header = systray.AddMenuItem("Loading accounts…", "")
	a.header.Disable()
	systray.AddSeparator()
	for i := 0; i < maxAccounts; i++ {
		item := systray.AddMenuItemCheckbox("", "Switch to this account", false)
		item.Hide()
		a.slots = append(a.slots, item)
		a.slotNums = append(a.slotNums, 0)
		go a.onSlot(i, item)
	}
	systray.AddSeparator()
	a.signIn = systray.AddMenuItem("Sign in another account…", "Sign in to Claude in a window and save that account")
	a.add = systray.AddMenuItem("Add current Claude login…", "Save the account Claude Code is logged in with now")
	a.rename = systray.AddMenuItem("Rename account…", "")
	a.remove = systray.AddMenuItem("Remove account…", "")
	systray.AddSeparator()
	a.autostart = systray.AddMenuItemCheckbox("Start at login", "", winutil.AutostartEnabled())
	a.reloadIDE = systray.AddMenuItemCheckbox("Reload VS Code after switching",
		"Restart Claude in VS Code and other editors so it uses the new account", a.settings.ReloadIDE)
	logs := systray.AddMenuItem("Open logs folder", "")
	about := systray.AddMenuItem(fmt.Sprintf("About %s %s / check for updates", appTitle, Version), "")
	systray.AddSeparator()
	quit := systray.AddMenuItem("Quit", "")

	go func() {
		for {
			select {
			case <-a.signIn.ClickedCh:
				go a.signInAccount(nil)
			case <-a.add.ClickedCh:
				go a.addCurrent()
			case <-a.rename.ClickedCh:
				go a.renameAccount(0)
			case <-a.remove.ClickedCh:
				go a.removeAccount(0)
			case <-a.reloadIDE.ClickedCh:
				a.toggleReloadIDE()
			case <-a.autostart.ClickedCh:
				a.toggleAutostart()
			case <-logs.ClickedCh:
				_ = os.MkdirAll(winutil.LogsDir(), 0o700)
				_ = winutil.Open(winutil.LogsDir())
			case <-about.ClickedCh:
				_ = winutil.Open(releasesURL)
			case <-quit.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()

	go a.loop()
}

func (a *app) loop() {
	cleanPendingProfiles()
	a.snapshot()
	a.refresh()
	a.verify()
	a.recoverIfNeeded()
	refresh := time.NewTicker(refreshEvery)
	verify := time.NewTicker(verifyEvery)
	snapshot := time.NewTicker(snapshotEvery)
	for {
		select {
		case <-refresh.C:
			a.refresh()
			a.recoverIfNeeded() // retries once a cooldown has passed
		case <-verify.C:
			a.verify()
			a.refresh()
			a.recoverIfNeeded()
		case <-snapshot.C:
			a.snapshot()
		}
	}
}

// snapshot keeps the active account's saved copy in step with the refresh
// tokens Claude Code rotates, so a login replaced outside Claude Swap
// (`claude /login`) does not strand the active account. csw refuses when
// Claude Code is logged in to another account; nothing to do then.
func (a *app) snapshot() {
	c, cancel := context.WithTimeout(context.Background(), listTimeout)
	defer cancel()
	_ = a.csw.SnapshotActive(c)
}

// refresh reloads the account list and redraws the menu.
func (a *app) refresh() {
	c, cancel := context.WithTimeout(context.Background(), listTimeout)
	defer cancel()
	res, err := a.csw.List(c)
	if err != nil {
		a.mu.Lock()
		a.loadErr = err.Error()
		a.mu.Unlock()
		a.setHeader("Could not load accounts: " + err.Error())
		return
	}
	a.mu.Lock()
	a.accounts = res.Accounts
	a.loadErr = ""
	a.mu.Unlock()
	a.redraw()
}

// refreshUsage reloads the accounts with usage for the popover. It calls
// Anthropic, so it runs when the popover opens (if stale) or on request.
func (a *app) refreshUsage() {
	a.mu.Lock()
	if a.loadingUsage {
		a.mu.Unlock()
		return
	}
	a.loadingUsage = true
	a.mu.Unlock()
	a.pushState()

	c, cancel := context.WithTimeout(context.Background(), 2*listTimeout)
	defer cancel()
	res, err := a.csw.ListWithUsage(c)
	a.mu.Lock()
	a.loadingUsage = false
	if err == nil {
		a.accounts = res.Accounts
		a.loadErr = ""
		a.usageAt = time.Now()
		for _, v := range res.Accounts {
			if v.Usage != nil {
				a.usage[v.Account.Number] = v.Usage
			}
		}
	}
	a.mu.Unlock()
	if err != nil {
		a.post("error", "Could not load usage: "+err.Error())
	}
	a.redraw()
}

// verify flags accounts whose saved login no longer works. It may refresh
// expired tokens (csw does so safely under its lock) and calls Anthropic.
func (a *app) verify() {
	dead, err := a.csw.NeedsLogin(context.Background())
	if err != nil {
		return
	}
	a.mu.Lock()
	a.needLogin = dead
	a.mu.Unlock()
	a.redraw()
}

func (a *app) redraw() {
	a.redrawMenu()
	a.pushState()
}

func (a *app) redrawMenu() {
	a.mu.Lock()
	defer a.mu.Unlock()
	active := "No account selected"
	for i, slot := range a.slots {
		if i >= len(a.accounts) {
			slot.Hide()
			a.slotNums[i] = 0
			continue
		}
		v := a.accounts[i]
		title := v.Account.DisplayName()
		if a.needLogin[v.Account.Number] {
			title += "  (needs login)"
		}
		slot.SetTitle(title)
		if v.IsActive {
			slot.Check()
			active = "Active: " + v.Account.DisplayName()
		} else {
			slot.Uncheck()
		}
		a.slotNums[i] = v.Account.Number
		slot.Show()
	}
	if len(a.accounts) == 0 {
		active = "No accounts yet — use “Sign in another account”"
	}
	if len(a.accounts) > len(a.slots) {
		active += fmt.Sprintf(" (+%d not shown)", len(a.accounts)-len(a.slots))
	}
	a.status = active
	a.header.SetTitle(active)
	systray.SetTooltip(truncate(appTitle+" — "+active, 120))
}

// setHeader shows a status line in place of the active account.
func (a *app) setHeader(text string) {
	a.mu.Lock()
	a.status = text
	a.header.SetTitle(truncate(text, 100))
	a.mu.Unlock()
	a.pushState()
}

// truncate keeps menu and tooltip text within Windows' fixed buffers.
func truncate(s string, max int) string {
	r := []rune(s)
	if len(r) <= max {
		return s
	}
	return string(r[:max-1]) + "…"
}

func (a *app) onSlot(i int, item *systray.MenuItem) {
	for range item.ClickedCh {
		a.mu.Lock()
		num := a.slotNums[i]
		a.mu.Unlock()
		a.switchTo(num)
	}
}

// begin marks operation op in flight; false means one is already running.
func (a *app) begin(op string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.busy != "" {
		return false
	}
	a.busy = op
	logf("%s: begin", op)
	return true
}

func (a *app) end() {
	a.mu.Lock()
	logf("%s: end", a.busy)
	a.busy = ""
	a.mu.Unlock()
}

// busyWith names the operation in flight.
func (a *app) busyWith() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.busy
}

func (a *app) account(num int) (cswclient.AccountView, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, v := range a.accounts {
		if v.Account.Number == num {
			return v, true
		}
	}
	return cswclient.AccountView{}, false
}

func (a *app) switchTo(num int) {
	v, ok := a.account(num)
	switch {
	case !ok:
		logf("switch %d: unknown account", num)
	case v.IsActive:
		logf("switch %d: already active", num)
	case !a.begin("Switch account"):
		logf("switch %d: skipped, %s still running", num, a.busyWith())
		a.post("error", "Wait for “"+a.busyWith()+"” to finish, then try again.")
	default:
		ok = false
	}
	if ok {
		a.redraw() // undo the checkbox toggle Windows applied on click
		return
	}
	defer a.end()
	logf("switch %d (%s): start", num, v.Account.DisplayName())
	a.mu.Lock()
	a.swapping = num
	a.mu.Unlock()
	a.setHeader("Switching to " + v.Account.DisplayName() + "…")
	err := a.csw.Switch(context.Background(), num)
	logf("switch %d: done, err=%v", num, err)
	a.mu.Lock()
	a.swapping = 0
	a.mu.Unlock()
	switch {
	case err == nil:
		// Terminal claude sessions pick the account up on their next
		// request; IDE sessions are restarted (reloadAfterSwitch).
		a.post("ok", "Switched to "+v.Account.DisplayName()+"."+a.switchDesktop(v.Account)+a.reloadAfterSwitch())
	case a.pop.Visible():
		a.post("error", "Switch to "+v.Account.DisplayName()+" failed: "+err.Error())
	default:
		showError("Switch to "+v.Account.DisplayName()+" failed", err)
	}
	a.refresh()
	if err == nil && a.pop.Visible() {
		a.refreshUsage()
	}
}

func (a *app) addCurrent() {
	if !a.begin("Add current login") {
		return
	}
	defer a.end()
	err := zenity.Question(
		"Claude Swap saves the account Claude Code is logged in with right now.\n\n"+
			"To add a different account, use “Sign in another account…” instead.",
		zenity.Title(appTitle), zenity.OKLabel("Add"), zenity.CancelLabel("Cancel"))
	if err != nil {
		return
	}
	nickname, err := zenity.Entry("Optional name for this account:", zenity.Title(appTitle))
	if err == zenity.ErrCanceled {
		return
	}
	res, err := a.csw.AddCurrent(context.Background(), nickname)
	switch {
	case err != nil:
		showError("Could not add the account", err)
	case res.WasDuplicate:
		go zenity.Info(res.Account.DisplayName()+" was already saved; its saved login was updated.", zenity.Title(appTitle)) // never hold the busy flag on a dialog
	}
	a.refresh()
}

// signInAccount adds an account by signing in to Claude in an embedded
// window (like the macOS app). The new login is only saved, never made
// live: Claude Code keeps its current account until the user switches.
//
// With again set it is a re-login of that account: it reuses the account's
// claude.ai session profile and refuses a different account.
func (a *app) signInAccount(again *cswclient.Account) {
	if !a.begin("Sign in") {
		return
	}
	defer a.end()
	var nickname, expected, profile string
	if again != nil {
		expected, profile = again.Email, profileFor(*again)
	} else {
		var err error
		nickname, err = zenity.Entry("Optional name for the account you are about to sign in with:", zenity.Title(appTitle))
		if err != nil {
			return
		}
		profile = newPendingProfile()
		defer func() { go removeProfileDir(profile) }() // no-op once adopted
	}
	ctx := context.Background()
	s, err := a.csw.StartSignIn(ctx)
	if err != nil {
		showError("Could not start sign-in", err)
		return
	}
	code, err := signInWindow(signInOpts{URL: s.URL, Profile: profile})
	if errors.Is(err, errNoWebView) {
		// No WebView2 runtime: sign in in the default browser and paste
		// the code the last page shows.
		_ = winutil.Open(s.URL)
		code, err = zenity.Entry("Sign in to Claude in your browser, then paste the code it shows:", zenity.Title(appTitle))
	}
	switch {
	case errors.Is(err, errSignInClosed):
		go zenity.Info("Sign-in was not completed, so no account was added.", zenity.Title(appTitle)) // never hold the busy flag on a dialog
		return
	case errors.Is(err, zenity.ErrCanceled):
		return
	case err != nil:
		showError("Sign-in failed", err)
		return
	}
	a.setHeader("Saving the account…")
	res, err := a.csw.AddSignedIn(ctx, s, code, nickname, expected)
	if err == nil {
		if again == nil {
			adoptProfile(profile, res.Account)
		}
		a.clearRecovery(res.Account.Number)
		a.mu.Lock()
		delete(a.needLogin, res.Account.Number)
		a.mu.Unlock()
	}
	switch {
	case err != nil:
		showError("Could not save the account", err)
	case again != nil:
		a.post("ok", "Signed "+again.DisplayName()+" in again.")
	case res.WasDuplicate:
		go zenity.Info(res.Account.DisplayName()+" was already saved; its saved login was updated.", zenity.Title(appTitle)) // never hold the busy flag on a dialog
	default:
		go zenity.Info("Added "+res.Account.DisplayName()+". Click the Claude Swap icon and pick it to switch Claude Code to it.", zenity.Title(appTitle)) // never hold the busy flag on a dialog
	}
	a.refresh()
}

// pick asks the user to choose an account; ok=false when cancelled.
func (a *app) pick(prompt string) (cswclient.AccountView, bool) {
	a.mu.Lock()
	names := make([]string, len(a.accounts))
	byName := map[string]cswclient.AccountView{}
	for i, v := range a.accounts {
		names[i] = fmt.Sprintf("%d. %s", v.Account.Number, v.Account.DisplayName())
		byName[names[i]] = v
	}
	a.mu.Unlock()
	if len(names) == 0 {
		go zenity.Info("No accounts saved yet.", zenity.Title(appTitle)) // never hold the busy flag on a dialog
		return cswclient.AccountView{}, false
	}
	choice, err := zenity.List(prompt, names, zenity.Title(appTitle), zenity.DisallowEmpty())
	if err != nil {
		return cswclient.AccountView{}, false
	}
	v, ok := byName[choice]
	return v, ok
}

// chosen returns account num, or asks the user to pick one when num is 0
// (the tray menu has no account context; the popover does).
func (a *app) chosen(num int, prompt string) (cswclient.AccountView, bool) {
	if num != 0 {
		return a.account(num)
	}
	return a.pick(prompt)
}

func (a *app) renameAccount(num int) {
	if !a.begin("Rename") {
		return
	}
	defer a.end()
	v, ok := a.chosen(num, "Rename which account?")
	if !ok {
		return
	}
	name, err := zenity.Entry("New name (leave empty to show the email):",
		zenity.Title(appTitle), zenity.EntryText(v.Account.Nickname))
	if err != nil {
		return
	}
	if err := a.csw.Rename(context.Background(), v.Account.Number, name); err != nil {
		showError("Rename failed", err)
	}
	a.refresh()
}

func (a *app) removeAccount(num int) {
	if !a.begin("Remove") {
		return
	}
	defer a.end()
	v, ok := a.chosen(num, "Remove which account?")
	if !ok {
		return
	}
	if v.IsActive {
		go zenity.Info("Switch to another account before removing the active one.", zenity.Title(appTitle)) // never hold the busy flag on a dialog
		return
	}
	if zenity.Question(fmt.Sprintf("Remove %s and its saved login from Claude Swap?\nClaude Code itself is not affected.", v.Account.DisplayName()),
		zenity.Title(appTitle), zenity.WarningIcon, zenity.OKLabel("Remove")) != nil {
		return
	}
	if err := a.csw.Remove(context.Background(), v.Account.Number); err != nil {
		showError("Remove failed", err)
	} else {
		a.clearRecovery(v.Account.Number)
		go removeProfileDir(profileFor(v.Account))
		_ = os.Remove(desktopSavePath(v.Account))
		setDesktopIndex(identityKey(v.Account), "")
	}
	a.refresh()
}

func (a *app) toggleAutostart() {
	on := !a.autostart.Checked()
	if err := winutil.SetAutostart(on); err != nil {
		go showError("Could not change start at login", err)
		return
	}
	if on {
		a.autostart.Check()
	} else {
		a.autostart.Uncheck()
	}
	a.pushState()
}

func (a *app) toggleReloadIDE() {
	a.mu.Lock()
	a.settings.ReloadIDE = !a.settings.ReloadIDE
	s := a.settings
	a.mu.Unlock()
	if err := saveSettings(s); err != nil {
		logf("save settings: %v", err)
	}
	if s.ReloadIDE {
		a.reloadIDE.Check()
	} else {
		a.reloadIDE.Uncheck()
	}
	a.pushState()
}

// reloadAfterSwitch restarts IDE Claude sessions when enabled and returns a
// sentence for the switch notice.
func (a *app) reloadAfterSwitch() string {
	a.mu.Lock()
	on := a.settings.ReloadIDE
	a.mu.Unlock()
	if !on {
		return " Running Claude Code sessions use it from their next request."
	}
	now, later := reloadIDESessions(func(pid int, restarted bool) {
		logf("ide reload: busy session %d restarted=%v", pid, restarted)
		if restarted {
			a.post("ok", "Restarted a VS Code Claude session that was busy; it now uses the new account.")
		}
	})
	logf("ide reload: restarted %d, waiting for %d busy", now, later)
	msg := " Terminal sessions use it from their next request."
	if now > 0 {
		msg += fmt.Sprintf(" Restarted %d VS Code Claude session(s).", now)
	}
	if later > 0 {
		msg += fmt.Sprintf(" %d busy VS Code session(s) restart once they finish answering.", later)
	}
	return msg
}

// notice is a short message shown at the bottom of the popover.
type notice struct {
	ID   int    `json:"id"`
	Kind string `json:"kind"` // "ok" or "error"
	Text string `json:"text"`
}

// post shows a notice in the popover.
func (a *app) post(kind, text string) {
	a.mu.Lock()
	id := 1
	if a.notice != nil {
		id = a.notice.ID + 1
	}
	a.notice = &notice{ID: id, Kind: kind, Text: text}
	a.mu.Unlock()
	a.pushState()
}

// popAccount is an account row as the popover page sees it.
type popAccount struct {
	cswclient.AccountView
	NeedsLogin bool `json:"needsLogin"`
	Recovering bool `json:"recovering"` // background re-login running
	CanRecover bool `json:"canRecover"` // a background re-login may still fix it
	HasDesktop bool `json:"hasDesktop"` // a Claude Desktop sign-in is saved
	InDesktop  bool `json:"inDesktop"`  // Claude Desktop is signed in to it
}

// pushState sends everything the popover shows to its page.
func (a *app) pushState() {
	if a.pop == nil {
		return
	}
	desktop, desktopInstalled := findDesktop()
	desktopUUID := ""
	if desktopInstalled {
		desktopUUID = desktop.accountUUID() // whose sign-in Desktop holds now
	}
	desktopIdx := desktopIndex()
	a.mu.Lock()
	accounts := make([]popAccount, len(a.accounts))
	for i, v := range a.accounts {
		if v.Usage == nil {
			v.Usage = a.usage[v.Account.Number]
		}
		num := v.Account.Number
		st := a.recovery[num]
		accounts[i] = popAccount{
			AccountView: v,
			NeedsLogin:  a.needLogin[num],
			Recovering:  a.recovering == num,
			CanRecover:  a.needLogin[num] && hasProfile(v.Account) && (st == nil || !st.manual),
			HasDesktop:  hasDesktopSave(v.Account),
			InDesktop:   desktopUUID != "" && desktopIdx[identityKey(v.Account)] == desktopUUID,
		}
	}
	state := map[string]any{
		"accounts":         accounts,
		"status":           a.status,
		"version":          Version,
		"autostart":        a.autostart != nil && a.autostart.Checked(),
		"reloadIDE":        a.settings.ReloadIDE,
		"switchDesktop":    a.settings.SwitchDesktop,
		"desktopInstalled": desktopInstalled,
		"loadingUsage": a.loadingUsage,
		"swapping":     a.swapping,
		"loadError":    a.loadErr,
		"notice":       a.notice,
	}
	a.mu.Unlock()
	a.pop.SetState(state)
}

// onPopoverAction handles a click in the popover. Actions that open a
// dialog hide the popover first: the dialog takes focus anyway.
func (a *app) onPopoverAction(action string, num int) {
	logf("popover: %s %d", action, num)
	switch action {
	case "shown":
		a.mu.Lock()
		stale := time.Since(a.usageAt) > time.Minute
		a.mu.Unlock()
		if stale {
			a.refreshUsage()
		}
	case "refresh":
		a.refreshUsage()
	case "switch":
		a.switchTo(num)
	case "signin":
		a.pop.Hide()
		a.signInAccount(nil)
	case "relogin":
		if v, ok := a.account(num); ok {
			a.pop.Hide()
			a.signInAccount(&v.Account)
		}
	case "addcurrent":
		a.pop.Hide()
		a.addCurrent()
	case "rename":
		a.pop.Hide()
		a.renameAccount(num)
	case "remove":
		a.pop.Hide()
		a.removeAccount(num)
	case "savedesktop":
		a.pop.Hide()
		a.saveDesktopLogin(num)
	case "desktopanother":
		a.desktopSignInAnother()
	case "switchdesktop":
		a.toggleSwitchDesktop()
	case "reloadide":
		a.toggleReloadIDE()
	case "autostart":
		a.toggleAutostart()
	case "logs":
		a.pop.Hide()
		_ = os.MkdirAll(winutil.LogsDir(), 0o700)
		_ = winutil.Open(winutil.LogsDir())
	case "about":
		a.pop.Hide()
		_ = winutil.Open(releasesURL)
	case "quit":
		systray.Quit()
	}
}

// showError uses a plain message box: toast notifications from an
// unregistered app are often dropped silently, and errors must be seen.
func showError(title string, err error) {
	// Async: a dialog hidden behind other windows must not keep an
	// operation marked as running (every later click would be refused).
	logf("error: %s: %v", title, err)
	go zenity.Error(err.Error(), zenity.Title(title))
}
