package main

import (
	"context"
	"encoding/json"
	"flag"
	"os"

	"github.com/soi/claude-swap-widget/backend/internal/usecase"
)

// runRefreshBundle collapses the widget's per-cycle poll — which previously
// forked three separate `csw` processes (list --metadata-only, sessions,
// usage-stats) — into a single invocation that returns all three payloads in
// one JSON object. Cuts the steady-state process spawns per refresh by ~66%
// with no change to the data the widget receives or its cadence.
//
// Error semantics mirror the Swift caller (AppStore.refreshNow):
//   - account metadata and the sessions report are REQUIRED; a failure in
//     either aborts the whole refresh so the widget keeps its last snapshot.
//   - usage-stats is BEST-EFFORT; its failure is swallowed and the key is
//     omitted so the widget keeps the last good token-burn value instead of
//     blanking the panel on a transient scan error.
func runRefreshBundle(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("refresh-bundle", flag.ExitOnError)
	// --json accepted for symmetry with the other commands; the bundle is
	// only ever emitted as JSON (its sole consumer is the widget).
	_ = fs.Bool("json", false, "machine-readable output (always on)")
	_ = fs.Parse(args)

	// Metadata only — the widget fetches per-account usage separately through
	// its web-scrape / OAuth fallback path, exactly as `list --metadata-only`
	// did on its own.
	listRes, err := svc.ListAccountsMetadata(ctx)
	if err != nil {
		return err
	}
	report, err := svc.SessionsReport(ctx)
	if err != nil {
		return err
	}

	out := map[string]any{
		"list":   listRes,
		"report": report,
	}
	// Best-effort: omit on failure rather than aborting the refresh.
	if stats, statsErr := svc.UsageStats(ctx); statsErr == nil {
		out["usageStats"] = stats
	}
	return json.NewEncoder(os.Stdout).Encode(out)
}
