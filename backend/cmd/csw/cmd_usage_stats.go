package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/usecase"
)

func runUsageStats(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("usage-stats", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	report, err := svc.UsageStats(ctx)
	if err != nil {
		return err
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(report)
	}
	printBucket("Today     ", report.Today)
	printBucket("This week ", report.ThisWeek)
	printBucket("This month", report.ThisMonth)
	return nil
}

func printBucket(label string, b domain.UsageBucket) {
	fmt.Printf("%s : %d tokens · $%.2f (in %d / out %d / cache_w %d / cache_r %d, %d req)\n",
		label,
		b.TotalTokens,
		b.EstimatedCostUsd,
		b.InputTokens, b.OutputTokens,
		b.CacheCreationTokens, b.CacheReadTokens,
		b.Requests,
	)
}
