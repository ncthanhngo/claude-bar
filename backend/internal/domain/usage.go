package domain

import "time"

// Usage represents Anthropic OAuth usage data for one account.
type Usage struct {
	FiveHour *Window `json:"fiveHour,omitempty"`
	SevenDay *Window `json:"sevenDay,omitempty"`
	// SevenDayScoped is the per-model weekly window the usage page renders
	// under "Weekly limits" next to the all-models bar (e.g. "Fable"). It
	// exists only in the API's `limits` array — the legacy `seven_day_opus`
	// style fields report null since the model rename.
	SevenDayScoped *Window `json:"sevenDayScoped,omitempty"`
	// ScopedLabel is the model display name for SevenDayScoped ("Fable").
	ScopedLabel string `json:"scopedLabel,omitempty"`
	FetchedAt time.Time `json:"fetchedAt"`
}

// Window is a single utilization window (5h or 7d).
type Window struct {
	UtilizationPct float64   `json:"utilizationPct"`
	ResetsAt       time.Time `json:"resetsAt"`
}

// SecondsUntilReset returns countdown in seconds (0 if past).
func (w *Window) SecondsUntilReset(now time.Time) int64 {
	if w == nil {
		return 0
	}
	diff := w.ResetsAt.Sub(now).Seconds()
	if diff < 0 {
		return 0
	}
	return int64(diff)
}

// HasPastResetWindow returns true when any window's ResetsAt is in the past.
// A cached Usage in that state describes a quota window that has already
// rolled over, so the cached utilization% and resetsAt are stale even if the
// cache entry itself is within its TTL.
func (u *Usage) HasPastResetWindow(now time.Time) bool {
	if u == nil {
		return false
	}
	if u.FiveHour != nil && u.FiveHour.ResetsAt.Before(now) {
		return true
	}
	if u.SevenDay != nil && u.SevenDay.ResetsAt.Before(now) {
		return true
	}
	return false
}
