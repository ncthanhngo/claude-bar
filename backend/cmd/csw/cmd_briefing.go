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

	briefingstore "github.com/soi/claude-swap-widget/backend/internal/adapter/storage/briefing"
	"github.com/soi/claude-swap-widget/backend/internal/mcp"
	"github.com/soi/claude-swap-widget/backend/internal/usecase"
	"github.com/soi/claude-swap-widget/backend/internal/usecase/briefing"
)

// runBriefing dispatches `csw briefing <run|show|schedule|action>`.
func runBriefing(ctx context.Context, svc *usecase.Service, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw briefing <run|show|schedule|action> ...")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "run":
		return runBriefingRun(ctx, svc, rest)
	case "show":
		return runBriefingShow(ctx, rest)
	case "schedule":
		return runBriefingSchedule(ctx, rest)
	case "action":
		return runBriefingAction(ctx, rest)
	default:
		return fmt.Errorf("unknown briefing subcommand: %s", sub)
	}
}

func runBriefingRun(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	force := fs.Bool("force", false, "re-run even if today's briefing exists")
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	store, err := briefingstore.New()
	if err != nil {
		return err
	}
	cfgStore, err := briefingstore.NewConfigStore()
	if err != nil {
		return err
	}
	schedule, lastDate, err := cfgStore.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	today := time.Now().Format("2006-01-02")
	if lastDate == today && !*force {
		if b, err := store.Load(today); err == nil {
			return emit(*asJSON, b)
		}
	}

	lock, err := briefingstore.NewRunLock()
	if err != nil {
		return err
	}
	lockCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	if err := lock.Acquire(lockCtx); err != nil {
		return err
	}
	defer lock.Release()

	res, err := svc.ListAccounts(ctx)
	if err != nil {
		return fmt.Errorf("active account: %w", err)
	}
	if res.ActiveAccountNumber == 0 {
		return errors.New("no active Claude Bar account")
	}

	gateway := mcp.New(svc.Registry, svc.MCPSecrets, cswVersion)
	runner := &briefing.Runner{
		Orchestrator: briefing.NewOrchestrator(gateway),
	}
	if claude, err := briefing.DefaultClaudeRunner(); err == nil {
		runner.Summarizer = claude
	}

	b, err := runner.Run(ctx, res.ActiveAccountNumber)
	if err != nil {
		return fmt.Errorf("briefing run: %w", err)
	}
	if err := store.Save(b); err != nil {
		return fmt.Errorf("save briefing: %w", err)
	}
	if err := cfgStore.Save(schedule, today); err != nil {
		return fmt.Errorf("save config: %w", err)
	}
	_, _ = store.Prune(30)

	return emit(*asJSON, b)
}

func runBriefingShow(_ context.Context, args []string) error {
	fs := flag.NewFlagSet("show", flag.ExitOnError)
	date := fs.String("date", time.Now().Format("2006-01-02"), "briefing date YYYY-MM-DD")
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	store, err := briefingstore.New()
	if err != nil {
		return err
	}
	b, err := store.Load(*date)
	if err != nil {
		return err
	}
	return emit(*asJSON, b)
}

func runBriefingSchedule(_ context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw briefing schedule <get|set|check>")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "get":
		return runScheduleGet(rest)
	case "set":
		return runScheduleSet(rest)
	case "check":
		return runScheduleCheck(rest)
	default:
		return fmt.Errorf("unknown schedule subcommand: %s", sub)
	}
}

func runScheduleGet(args []string) error {
	fs := flag.NewFlagSet("get", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	cfgStore, err := briefingstore.NewConfigStore()
	if err != nil {
		return err
	}
	s, lastDate, err := cfgStore.Load()
	if err != nil {
		return err
	}
	s.LastRunAt = lastDate
	return emit(*asJSON, s)
}

func runScheduleSet(args []string) error {
	fs := flag.NewFlagSet("set", flag.ExitOnError)
	cronExpr := fs.String("cron", "", "5-field cron in local time")
	enabledStr := fs.String("enabled", "", "true|false")
	tz := fs.String("tz", "", "IANA timezone (e.g. Asia/Saigon)")
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	cfgStore, err := briefingstore.NewConfigStore()
	if err != nil {
		return err
	}
	s, lastDate, err := cfgStore.Load()
	if err != nil {
		return err
	}
	if *cronExpr != "" {
		if _, err := briefing.ParseCron(*cronExpr); err != nil {
			return err
		}
		s.CronExpr = *cronExpr
	}
	if *enabledStr != "" {
		b, err := strconv.ParseBool(*enabledStr)
		if err != nil {
			return fmt.Errorf("--enabled must be true|false")
		}
		s.Enabled = b
	}
	if *tz != "" {
		if _, err := time.LoadLocation(*tz); err != nil {
			return fmt.Errorf("invalid timezone: %v", err)
		}
		s.Timezone = *tz
	}
	if err := cfgStore.Save(s, lastDate); err != nil {
		return err
	}
	return emit(*asJSON, s)
}

func runScheduleCheck(args []string) error {
	fs := flag.NewFlagSet("check", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	cfgStore, err := briefingstore.NewConfigStore()
	if err != nil {
		return err
	}
	s, lastDate, err := cfgStore.Load()
	if err != nil {
		return err
	}
	now := time.Now()
	next, _ := briefing.NextRunAt(now, s.CronExpr, s.Timezone)
	result := map[string]any{
		"shouldRun":        briefing.ShouldRun(now, s, lastDate),
		"nextRunAt":        next.Format(time.RFC3339),
		"lastBriefingDate": lastDate,
		"enabled":          s.Enabled,
	}
	return emit(*asJSON, result)
}

func runBriefingAction(_ context.Context, args []string) error {
	if len(args) == 0 || args[0] != "toggle" {
		return errors.New("usage: csw briefing action toggle --date YYYY-MM-DD --id ID --done true|false")
	}
	fs := flag.NewFlagSet("toggle", flag.ExitOnError)
	date := fs.String("date", time.Now().Format("2006-01-02"), "briefing date")
	id := fs.String("id", "", "action ID")
	doneStr := fs.String("done", "true", "true|false")
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args[1:])

	if *id == "" {
		return errors.New("--id is required")
	}
	done, err := strconv.ParseBool(*doneStr)
	if err != nil {
		return fmt.Errorf("--done must be true|false")
	}
	store, err := briefingstore.New()
	if err != nil {
		return err
	}
	if err := store.ToggleAction(*date, *id, done); err != nil {
		return err
	}
	b, err := store.Load(*date)
	if err != nil {
		return err
	}
	return emit(*asJSON, b)
}

// emit writes v as JSON to stdout when asJSON; otherwise pretty-print one-line summary.
func emit(asJSON bool, v any) error {
	if asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(v)
	}
	switch x := v.(type) {
	case *briefing.Briefing:
		fmt.Printf("Briefing %s — %d actions, %d events. Generated %s.\n",
			x.Date, len(x.Actions), len(x.Calendar), x.GeneratedAt.Format(time.RFC3339))
	default:
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(v)
	}
	return nil
}
