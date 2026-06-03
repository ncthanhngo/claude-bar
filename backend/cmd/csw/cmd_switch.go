package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/lock"
	"github.com/soi/claude-swap-widget/backend/internal/usecase"
)

// switchAcquireTimeout bounds total swap time (file-lock wait + Keychain
// writes + OAuth refresh + config write). 30s gives slow OAuth refresh
// paths plenty of slack while still failing fast on an orphaned lock
// holder instead of hanging the UI indefinitely.
const switchAcquireTimeout = 30 * time.Second

func runSwitch(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("switch", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	if fs.NArg() < 1 {
		return fmt.Errorf("usage: csw switch <num|label>")
	}
	// Accept either a bare account number or a label (nickname / email /
	// display name) so users can `csw switch work` instead of memorising
	// numbers. Resolving also gives us the display name for a friendly
	// confirmation that matches the menu-bar swap notification.
	num, name, err := resolveAccount(ctx, svc, fs.Arg(0))
	if err != nil {
		return err
	}
	swapCtx, cancel := context.WithTimeout(ctx, switchAcquireTimeout)
	defer cancel()
	if err := svc.SwitchAccount(swapCtx, num); err != nil {
		if errors.Is(err, lock.ErrAcquireTimeout) {
			return fmt.Errorf("swap busy: another csw operation is holding the lock (waited %s). Retry shortly; if this persists, no other csw is running so the lock file may be stale.", switchAcquireTimeout)
		}
		return err
	}
	if *asJSON {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{
			"ok":                  true,
			"activeAccountNumber": num,
			"activeAccountName":   name,
			"hint":                "restart claude (or quit IDE plugin) to pick up the new credentials",
		})
		return nil
	}
	fmt.Printf("Switched to %s (account %d). Restart `claude` to use the new credentials.\n", name, num)
	return nil
}

// resolveAccount maps a switch target to (number, displayName) using metadata
// only (no usage fetches, so it stays fast). The target is either a bare
// account number or a label matched case-insensitively, ordered by
// specificity:
//
//  1. numeric → that exact account number
//  2. exact nickname, email, or display name
//  3. otherwise, a unique substring match on nickname/email
//
// A missing number, zero matches, or an ambiguous substring all error with the
// candidate list so the user can pick a number or a sharper label.
func resolveAccount(ctx context.Context, svc *usecase.Service, target string) (int, string, error) {
	res, err := svc.ListAccountsMetadata(ctx)
	if err != nil {
		return 0, "", err
	}
	if len(res.Accounts) == 0 {
		return 0, "", fmt.Errorf("no accounts yet — run: csw add")
	}

	if num, convErr := strconv.Atoi(strings.TrimSpace(target)); convErr == nil {
		for _, v := range res.Accounts {
			if v.Account.Number == num {
				return num, v.Account.DisplayName(), nil
			}
		}
		return 0, "", fmt.Errorf("no account numbered %d. Known accounts:\n%s", num, formatAccountChoices(res.Accounts))
	}

	want := strings.ToLower(strings.TrimSpace(target))
	var substringHits []*usecase.AccountView
	for _, v := range res.Accounts {
		a := v.Account
		if strings.EqualFold(a.Nickname, target) ||
			strings.EqualFold(a.Email, target) ||
			strings.EqualFold(a.DisplayName(), target) {
			return a.Number, a.DisplayName(), nil
		}
		if want != "" && (strings.Contains(strings.ToLower(a.Nickname), want) ||
			strings.Contains(strings.ToLower(a.Email), want)) {
			substringHits = append(substringHits, v)
		}
	}

	switch len(substringHits) {
	case 1:
		return substringHits[0].Account.Number, substringHits[0].Account.DisplayName(), nil
	case 0:
		return 0, "", fmt.Errorf("no account matching %q. Known accounts:\n%s", target, formatAccountChoices(res.Accounts))
	default:
		return 0, "", fmt.Errorf("%q is ambiguous, matches:\n%s", target, formatAccountChoices(substringHits))
	}
}

// formatAccountChoices renders "  <num>  <display>  <email>" lines for error
// hints so the user can immediately retry with a number or sharper label.
func formatAccountChoices(views []*usecase.AccountView) string {
	var b strings.Builder
	for _, v := range views {
		a := v.Account
		fmt.Fprintf(&b, "  %d  %s  <%s>\n", a.Number, a.DisplayName(), a.Email)
	}
	return strings.TrimRight(b.String(), "\n")
}

func runActive(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("active", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	res, err := svc.ListAccounts(ctx)
	if err != nil {
		return err
	}
	if *asJSON {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{
			"activeAccountNumber": res.ActiveAccountNumber,
		})
		return nil
	}
	fmt.Println(res.ActiveAccountNumber)
	return nil
}
