package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"strconv"
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
		return fmt.Errorf("usage: csw switch <num>")
	}
	num, err := strconv.Atoi(fs.Arg(0))
	if err != nil {
		return fmt.Errorf("invalid account number: %s", fs.Arg(0))
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
			"ok":              true,
			"activeAccountNumber": num,
			"hint":            "restart claude (or quit IDE plugin) to pick up the new credentials",
		})
		return nil
	}
	fmt.Printf("Switched to account %d. Restart `claude` to use the new credentials.\n", num)
	return nil
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
