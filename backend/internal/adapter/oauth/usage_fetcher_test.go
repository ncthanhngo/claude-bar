package oauth

import (
	"encoding/json"
	"testing"
)

// The per-model weekly window ("Fable") is reported only inside the `limits`
// array — the legacy seven_day_opus field reports null since the model rename.
const limitsJSON = `[
  {"kind": "session", "percent": 11, "resets_at": "2026-09-10T06:39:59.911770+00:00", "scope": null},
  {"kind": "weekly_all", "percent": 70, "resets_at": "2026-09-11T11:59:59.911790+00:00", "scope": null},
  {"kind": "weekly_scoped", "percent": 83, "resets_at": "2026-09-11T11:59:59.911939+00:00",
   "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}
]`

func decodeLimits(t *testing.T, raw string) []limitDTO {
	t.Helper()
	var limits []limitDTO
	if err := json.Unmarshal([]byte(raw), &limits); err != nil {
		t.Fatalf("unmarshal limits: %v", err)
	}
	return limits
}

func TestScopedWeekly_PicksPerModelWindow(t *testing.T) {
	w, label := scopedWeekly(decodeLimits(t, limitsJSON))
	if w == nil {
		t.Fatal("scoped weekly window not parsed")
	}
	if w.UtilizationPct != 83 {
		t.Errorf("utilization = %v, want 83", w.UtilizationPct)
	}
	if label != "Fable" {
		t.Errorf("label = %q, want Fable", label)
	}
	// A zero ResetsAt reads as an already-rolled-over window downstream.
	if w.ResetsAt.IsZero() {
		t.Error("resetsAt is zero")
	}
}

func TestScopedWeekly_NoPerModelEntry(t *testing.T) {
	raw := `[{"kind": "weekly_all", "percent": 10, "resets_at": "2026-09-11T11:59:59Z", "scope": null}]`
	if w, label := scopedWeekly(decodeLimits(t, raw)); w != nil || label != "" {
		t.Errorf("expected no scoped window, got %+v / %q", w, label)
	}
}

// An entry whose resets_at is null or unparseable is skipped rather than
// stored with a zero time.
func TestScopedWeekly_SkipsUnparseableReset(t *testing.T) {
	raw := `[{"kind": "weekly_scoped", "percent": 83, "resets_at": null,
	          "scope": {"model": {"display_name": "Fable"}}}]`
	if w, _ := scopedWeekly(decodeLimits(t, raw)); w != nil {
		t.Errorf("expected skip, got %+v", w)
	}
}
