package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/soi/claude-swap-widget/backend/internal/usecase"
)

func runSnapshotActive(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("snapshot-active", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	if err := svc.SnapshotActiveLive(ctx); err != nil {
		return err
	}
	if *asJSON {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": true})
		return nil
	}
	fmt.Println("Snapshotted active account live credentials into backup.")
	return nil
}
