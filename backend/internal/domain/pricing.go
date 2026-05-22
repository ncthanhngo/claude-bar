package domain

// ModelPricing is Anthropic's published per-1M-token rate for one model family.
// The four flows mirror the usage block Claude Code records per assistant
// message (input, output, cache_creation, cache_read). Values are in USD.
//
// This is the single source of truth for both:
//   - the estimated-cost column in the usage stats report
//     (adapter/usagelog/pricing.go applies these rates to each message)
//   - the "Details" popover on the Claude tab in the widget
//     (shipped to the widget via UsageStatsReport.Pricing).
//
// Update PublishedPricing when Anthropic adjusts rates; both surfaces refresh
// automatically on the next scan.
type ModelPricing struct {
	Family     string  `json:"family"`
	Input      float64 `json:"input"`
	Output     float64 `json:"output"`
	CacheWrite float64 `json:"cacheWrite"`
	CacheRead  float64 `json:"cacheRead"`
}

// PublishedPricingReference labels the source + last-known-good date for the
// rates below. Shown verbatim in the widget's "Details" panel so it should
// read as a sentence the user can act on (open the URL, check the date).
const PublishedPricingReference = "Nguồn: anthropic.com/pricing · cập nhật 2026-05"

// PublishedPricing returns Anthropic's per-model rates in USD per 1M tokens.
// Order is stable (opus → sonnet → haiku) so the widget's table renders the
// same way every scan.
func PublishedPricing() []ModelPricing {
	return []ModelPricing{
		{Family: "opus", Input: 15.00, Output: 75.00, CacheWrite: 18.75, CacheRead: 1.50},
		{Family: "sonnet", Input: 3.00, Output: 15.00, CacheWrite: 3.75, CacheRead: 0.30},
		{Family: "haiku", Input: 0.80, Output: 4.00, CacheWrite: 1.00, CacheRead: 0.08},
	}
}
