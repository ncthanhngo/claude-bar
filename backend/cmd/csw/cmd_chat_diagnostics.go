package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/usecase/chat"
)

// runChatDiagnostics dispatches `csw chat diagnostics <sub>`.
//   - report → JSON counts + disk usage for the active account
//   - test-prompt → roundtrip ping, prints latency_ms
//   - prune --days N → delete conversations older than N days, prints count
func runChatDiagnostics(ctx context.Context, svc *chat.Service, accountNum int, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw chat diagnostics <report|test-prompt|prune> ...")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "report":
		return runDiagReport(ctx, svc, accountNum)
	case "test-prompt":
		return runDiagTestPrompt(ctx, svc, accountNum)
	case "prune":
		return runDiagPrune(ctx, svc, accountNum, rest)
	default:
		return fmt.Errorf("unknown diagnostics subcommand: %s", sub)
	}
}

func runDiagReport(ctx context.Context, svc *chat.Service, accountNum int) error {
	report, err := svc.CollectDiagnostics(ctx, accountNum)
	if err != nil {
		return err
	}
	return writeJSON(report)
}

func runDiagTestPrompt(ctx context.Context, svc *chat.Service, accountNum int) error {
	latencyMs, err := svc.TestPrompt(ctx, accountNum)
	if err != nil {
		return err
	}
	return writeJSON(map[string]any{
		"ok":         true,
		"latency_ms": latencyMs,
	})
}

func runDiagPrune(ctx context.Context, svc *chat.Service, accountNum int, args []string) error {
	fs := flag.NewFlagSet("prune", flag.ContinueOnError)
	days := fs.Int("days", 0, "delete conversations older than N days (>0 required)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *days <= 0 {
		return errors.New("--days must be positive (e.g. --days 30)")
	}
	deleted, err := svc.PruneOlderThan(ctx, accountNum, time.Duration(*days)*24*time.Hour)
	if err != nil {
		return err
	}
	return writeJSON(map[string]any{
		"deleted_count":      deleted,
		"older_than_days":    *days,
	})
}
