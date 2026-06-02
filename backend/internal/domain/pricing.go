package domain

// ModelPricing is Anthropic's published per-1M-token rate for one model family.
// The four flows mirror the usage block Claude Code records per assistant
// message (input, output, cache_creation, cache_read). Values are in USD.
//
// Retained only as the element type of UsageStatsReport.Pricing, which keeps
// the widget's JSON contract stable. The dollar-cost columns are no longer
// populated (subscription accounts don't pay per token, so the estimate was
// misleading) — the report ships an empty Pricing array.
type ModelPricing struct {
	Family     string  `json:"family"`
	Input      float64 `json:"input"`
	Output     float64 `json:"output"`
	CacheWrite float64 `json:"cacheWrite"`
	CacheRead  float64 `json:"cacheRead"`
}
