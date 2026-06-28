package domain

import "time"

// UsageStatsReport aggregates Claude Code token usage across calendar windows.
// Source = local JSONL session logs written by the Claude Code CLI and the
// VSCode/IDE extensions (they share ~/.claude/projects/). Account attribution
// is intentionally absent: JSONL does not record which OAuth account was
// active, so the report sums across all accounts the user has used locally.
type UsageStatsReport struct {
	Today              UsageBucket    `json:"today"`
	ThisWeek           UsageBucket    `json:"thisWeek"`
	ThisMonth          UsageBucket    `json:"thisMonth"`
	Hourly             []TimedBucket  `json:"hourly"`  // last 24 hours, hour-aligned, oldest first
	Daily              []TimedBucket  `json:"daily"`   // last 30 days, day-aligned, oldest first
	Monthly            []TimedBucket  `json:"monthly"` // last 12 months, month-aligned, oldest first
	Pricing            []ModelPricing `json:"pricing"`
	PricingReference   string         `json:"pricingReference"`
	FetchedAt          time.Time      `json:"fetchedAt"`
}

// TimedBucket is one slot in a histogram series. Start is the inclusive lower
// bound of the slot; the upper bound is implicit (next slot's Start, or now
// for the final slot).
type TimedBucket struct {
	Start  time.Time   `json:"start"`
	Bucket UsageBucket `json:"bucket"`
}

// UsageBucket is a single calendar window's totals.
//
// TotalTokens is the complete count of tokens processed: input + output +
// cache_creation + cache_read. Every token Anthropic reports in a message's
// usage block is included so the figure matches the true volume consumed
// (same total ccusage reports). The four components remain in their own
// fields for the breakdown.
//
// EstimatedCostUsd is retained for JSON-contract stability but is no longer
// populated — it always serialises as 0. Dollar estimates were dropped because
// subscription accounts don't pay per token, so the figure was misleading.
type UsageBucket struct {
	InputTokens         int64   `json:"inputTokens"`
	OutputTokens        int64   `json:"outputTokens"`
	CacheCreationTokens int64   `json:"cacheCreationTokens"`
	CacheReadTokens     int64   `json:"cacheReadTokens"`
	TotalTokens         int64   `json:"totalTokens"`
	// CostEquivalentTokens normalises the four flows to input-token equivalents
	// using Anthropic's per-flow price ratios — output 5×, cache write 1.25×,
	// cache read 0.1× input. These ratios are identical across the Claude model
	// lineup, so the figure is exact regardless of model mix and needs no dollar
	// price table. It answers "how heavy was this in billable terms", which the
	// raw TotalTokens overstates because cache reads (0.1× price) dominate it.
	CostEquivalentTokens int64   `json:"costEquivalentTokens"`
	EstimatedCostUsd     float64 `json:"estimatedCostUsd"`
	Requests             int     `json:"requests"`
}

// Add merges one assistant message's usage into the bucket.
func (b *UsageBucket) Add(input, output, cacheCreate, cacheRead int64) {
	b.InputTokens += input
	b.OutputTokens += output
	b.CacheCreationTokens += cacheCreate
	b.CacheReadTokens += cacheRead
	// All four components included — total = complete tokens processed.
	b.TotalTokens += input + output + cacheCreate + cacheRead
	// Recompute from the running totals (not per-message) so the two integer
	// divisions round once against the aggregate, not 1000× against each line.
	b.CostEquivalentTokens = b.InputTokens +
		b.OutputTokens*5 +
		b.CacheCreationTokens*5/4 +
		b.CacheReadTokens/10
	b.Requests++
}
