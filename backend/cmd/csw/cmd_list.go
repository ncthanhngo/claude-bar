package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/usecase"
)

func runList(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("list", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	metadataOnly := fs.Bool("metadata-only", false, "skip usage fetches")
	usageAccountsFlag := fs.String("usage-accounts", "", "comma-separated account numbers to fetch usage for")
	_ = fs.Parse(args)

	var res *usecase.ListAccountsResult
	var err error
	if *metadataOnly {
		res, err = svc.ListAccountsMetadata(ctx)
	} else if *usageAccountsFlag != "" {
		res, err = svc.ListAccountsUsageFor(ctx, parseUsageAccounts(*usageAccountsFlag))
	} else {
		res, err = svc.ListAccounts(ctx)
	}
	if err != nil {
		return err
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(res)
	}
	printList(res)
	return nil
}

func parseUsageAccounts(raw string) map[int]bool {
	out := map[int]bool{}
	for _, part := range strings.Split(raw, ",") {
		num, err := strconv.Atoi(strings.TrimSpace(part))
		if err == nil && num > 0 {
			out[num] = true
		}
	}
	return out
}

func printList(r *usecase.ListAccountsResult) {
	if len(r.Accounts) == 0 {
		fmt.Println("(no accounts yet — run: csw add)")
		return
	}
	fmt.Println("Accounts:")
	now := time.Now()
	for _, v := range r.Accounts {
		marker := " "
		if v.IsActive {
			marker = "▸"
		}
		fmt.Printf("  %s %d  %-30s  %s\n", marker, v.Account.Number, v.Account.DisplayName(), tagForOrg(v.Account))
		fmt.Printf("       %s\n", v.Account.Email)
		if v.Error != "" {
			fmt.Printf("       usage: %s\n", v.Error)
			continue
		}
		if v.Usage == nil {
			continue
		}
		fmt.Printf("       5h: %s    7d: %s\n", windowStr(v.Usage.FiveHour, now), windowStr(v.Usage.SevenDay, now))
	}
}

func windowStr(w *domain.Window, now time.Time) string {
	if w == nil {
		return "—"
	}
	secs := w.SecondsUntilReset(now)
	return fmt.Sprintf("%3.0f%% (resets in %s)", w.UtilizationPct*100, durationShort(secs))
}

func durationShort(secs int64) string {
	if secs <= 0 {
		return "now"
	}
	h := secs / 3600
	m := (secs % 3600) / 60
	if h > 24 {
		d := h / 24
		return fmt.Sprintf("%dd %dh", d, h%24)
	}
	if h > 0 {
		return fmt.Sprintf("%dh %02dm", h, m)
	}
	return fmt.Sprintf("%dm", m)
}

func tagForOrg(a *domain.Account) string {
	if a.OrganizationName == "" {
		return ""
	}
	return "[" + a.OrganizationName + "]"
}
