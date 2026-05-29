package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/soi/claude-swap-widget/backend/internal/usecase"
)

// runAddAccountOAuth creates a NEW account from an OAuth payload exchanged by
// the Swift in-app WebView add-account flow. The JSON arrives on stdin so the
// access/refresh tokens never appear in argv or shell history.
//
// Stdin shape: see usecase.AddAccountFromOAuthInput. Identity (email + orgUuid)
// is part of the payload, sourced from the token-exchange response.
func runAddAccountOAuth(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("add-oauth", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		return fmt.Errorf("read stdin: %w", err)
	}
	if len(raw) == 0 {
		return fmt.Errorf("add-oauth: empty stdin (expected JSON payload)")
	}
	var in usecase.AddAccountFromOAuthInput
	if err := json.Unmarshal(raw, &in); err != nil {
		return fmt.Errorf("decode stdin payload: %w", err)
	}

	res, err := svc.AddAccountFromOAuth(ctx, in)
	if err != nil {
		return err
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(res)
	}
	if res.WasDuplicate {
		fmt.Printf("⚠ Account %s already existed as Account-%d. Backup credentials refreshed.\n",
			res.Account.Email, res.DuplicateOfNum)
	} else {
		fmt.Printf("Added Account-%d (%s).\n", res.Account.Number, res.Account.DisplayName())
	}
	return nil
}
