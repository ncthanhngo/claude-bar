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

// runIngestOAuth ingests an OAuth payload produced by the Swift in-app WebView
// re-login flow. The JSON arrives on stdin so access/refresh tokens never
// appear in argv or shell history.
//
// Stdin shape: see usecase.IngestOAuthInput. The account number is part of the
// payload (not an argv positional) to match the file-format used elsewhere for
// stdin-driven csw commands.
func runIngestOAuth(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("ingest-oauth", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		return fmt.Errorf("read stdin: %w", err)
	}
	if len(raw) == 0 {
		return fmt.Errorf("ingest-oauth: empty stdin (expected JSON payload)")
	}
	var in usecase.IngestOAuthInput
	if err := json.Unmarshal(raw, &in); err != nil {
		return fmt.Errorf("decode stdin payload: %w", err)
	}

	res, err := svc.IngestOAuthPayload(ctx, in)
	if err != nil {
		return err
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(res)
	}
	fmt.Printf("Re-logged Account-%d (%s). live=%v backup=%v\n",
		res.Account.Number, res.Account.DisplayName(), res.WroteLive, res.WroteBackup)
	return nil
}
