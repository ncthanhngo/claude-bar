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
// TotalTokens excludes cache reads on purpose: cache reads are billed at ~10%
// of input and dominate the raw count for any long-running session, which
// makes the "total" number unreadable as a usage signal. Cache reads are kept
// in their own field so users still see them in the breakdown.
//
// EstimatedCostUsd applies Anthropic's per-model published pricing
// (see adapter/usagelog/pricing.go) and IS computed across all four token
// flows including cache reads (cache reads aren't free even if they're cheap).
type UsageBucket struct {
	InputTokens         int64   `json:"inputTokens"`
	OutputTokens        int64   `json:"outputTokens"`
	CacheCreationTokens int64   `json:"cacheCreationTokens"`
	CacheReadTokens     int64   `json:"cacheReadTokens"`
	TotalTokens         int64   `json:"totalTokens"`
	EstimatedCostUsd    float64 `json:"estimatedCostUsd"`
	Requests            int     `json:"requests"`
}

// Add merges one assistant message's usage + estimated cost into the bucket.
func (b *UsageBucket) Add(input, output, cacheCreate, cacheRead int64, costUsd float64) {
	b.InputTokens += input
	b.OutputTokens += output
	b.CacheCreationTokens += cacheCreate
	b.CacheReadTokens += cacheRead
	// Cache reads excluded from TotalTokens — see type doc.
	b.TotalTokens += input + output + cacheCreate
	b.EstimatedCostUsd += costUsd
	b.Requests++
}
