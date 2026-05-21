package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/soi/claude-swap-widget/backend/internal/usecase"
)

func runRepairKeychain(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("repair-keychain", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	if err := svc.RepairLiveCredential(ctx); err != nil {
		return err
	}
	if *asJSON {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{
			"ok":   true,
			"hint": "restart claude so it reopens the repaired Keychain item",
		})
		return nil
	}
	fmt.Println("Repaired live Claude Code Keychain item. Restart `claude` to reopen it.")
	return nil
}
