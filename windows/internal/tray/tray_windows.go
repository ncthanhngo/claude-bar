//go:build windows

// Package tray is the notification-area menu: list accounts, switch, add,
// rename, remove.
package tray

import (
	"context"
	_ "embed"
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
	// listTimeout bounds the read-only list. Other csw commands are never
	// killed: a kill between a token refresh and its save loses the login.
	listTimeout = 30 * time.Second
	releasesURL = "https://github.com/ncthanhngo/claude-bar/releases"
)

// Version is stamped at build time.
var Version = "dev"

type app struct {
	csw *cswclient.Client

	mu        sync.Mutex
	busy      bool
	accounts  []cswclient.AccountView
	needLogin map[int]bool

	header    *systray.MenuItem
	slots     []*systray.MenuItem
	slotNums  []int
	add       *systray.MenuItem
	rename    *systray.MenuItem
	remove    *systray.MenuItem
	autostart *systray.MenuItem
}

// Run blocks until the user quits.
func Run(csw *cswclient.Client) {
	a := &app{csw: csw, needLogin: map[int]bool{}}
	systray.Run(a.onReady, func() {})
}

func (a *app) onReady() {
	systray.SetIcon(icon)
	systray.SetTitle(appTitle)
	systray.SetTooltip(appTitle)

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
	a.add = systray.AddMenuItem("Add current Claude login…", "Save the account Claude Code is logged in with now")
	a.rename = systray.AddMenuItem("Rename account…", "")
	a.remove = systray.AddMenuItem("Remove account…", "")
	systray.AddSeparator()
	a.autostart = systray.AddMenuItemCheckbox("Start at login", "", winutil.AutostartEnabled())
	logs := systray.AddMenuItem("Open logs folder", "")
	about := systray.AddMenuItem(fmt.Sprintf("About %s %s / check for updates", appTitle, Version), "")
	systray.AddSeparator()
	quit := systray.AddMenuItem("Quit", "")

	go func() {
		for {
			select {
			case <-a.add.ClickedCh:
				go a.addCurrent()
			case <-a.rename.ClickedCh:
				go a.renameAccount()
			case <-a.remove.ClickedCh:
				go a.removeAccount()
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
	a.refresh()
	a.verify()
	refresh := time.NewTicker(refreshEvery)
	verify := time.NewTicker(verifyEvery)
	for {
		select {
		case <-refresh.C:
			a.refresh()
		case <-verify.C:
			a.verify()
			a.refresh()
		}
	}
}

// refresh reloads the account list and redraws the menu.
func (a *app) refresh() {
	c, cancel := context.WithTimeout(context.Background(), listTimeout)
	defer cancel()
	res, err := a.csw.List(c)
	if err != nil {
		a.setHeader("Could not load accounts: " + err.Error())
		return
	}
	a.mu.Lock()
	a.accounts = res.Accounts
	a.mu.Unlock()
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
		active = "No accounts yet — use “Add current Claude login”"
	}
	if len(a.accounts) > len(a.slots) {
		active += fmt.Sprintf(" (+%d not shown)", len(a.accounts)-len(a.slots))
	}
	a.header.SetTitle(active)
	systray.SetTooltip(truncate(appTitle+" — "+active, 120))
}

// setHeader shows a status line in place of the active account.
func (a *app) setHeader(text string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.header.SetTitle(truncate(text, 100))
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

// begin marks an operation in flight; false means one is already running.
func (a *app) begin() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.busy {
		return false
	}
	a.busy = true
	return true
}

func (a *app) end() {
	a.mu.Lock()
	a.busy = false
	a.mu.Unlock()
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
	if !ok || v.IsActive || !a.begin() {
		a.redraw() // undo the checkbox toggle Windows applied on click
		return
	}
	defer a.end()
	a.setHeader("Switching to " + v.Account.DisplayName() + "…")
	if err := a.csw.Switch(context.Background(), num); err != nil {
		showError("Switch to "+v.Account.DisplayName()+" failed", err)
	}
	// Success shows as the new "Active:" line; running claude sessions pick
	// the account up on their next request.
	a.refresh()
}

func (a *app) addCurrent() {
	if !a.begin() {
		return
	}
	defer a.end()
	err := zenity.Question(
		"Claude Swap saves the account Claude Code is logged in with right now.\n\n"+
			"To add another account, first run  claude /login  in a terminal and sign in with it, then choose Add.",
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
		_ = zenity.Info(res.Account.DisplayName()+" was already saved; its saved login was updated.", zenity.Title(appTitle))
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
		_ = zenity.Info("No accounts saved yet.", zenity.Title(appTitle))
		return cswclient.AccountView{}, false
	}
	choice, err := zenity.List(prompt, names, zenity.Title(appTitle), zenity.DisallowEmpty())
	if err != nil {
		return cswclient.AccountView{}, false
	}
	v, ok := byName[choice]
	return v, ok
}

func (a *app) renameAccount() {
	if !a.begin() {
		return
	}
	defer a.end()
	v, ok := a.pick("Rename which account?")
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

func (a *app) removeAccount() {
	if !a.begin() {
		return
	}
	defer a.end()
	v, ok := a.pick("Remove which account?")
	if !ok {
		return
	}
	if v.IsActive {
		_ = zenity.Info("Switch to another account before removing the active one.", zenity.Title(appTitle))
		return
	}
	if zenity.Question(fmt.Sprintf("Remove %s and its saved login from Claude Swap?\nClaude Code itself is not affected.", v.Account.DisplayName()),
		zenity.Title(appTitle), zenity.WarningIcon, zenity.OKLabel("Remove")) != nil {
		return
	}
	if err := a.csw.Remove(context.Background(), v.Account.Number); err != nil {
		showError("Remove failed", err)
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
}

// showError uses a plain message box: toast notifications from an
// unregistered app are often dropped silently, and errors must be seen.
func showError(title string, err error) {
	_ = zenity.Error(err.Error(), zenity.Title(title))
}
