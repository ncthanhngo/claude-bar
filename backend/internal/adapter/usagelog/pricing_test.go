package usagelog

import (
	"math"
	"testing"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

func approxEqual(a, b float64) bool {
	return math.Abs(a-b) < 1e-9
}

func bundledRates() rateIndex { return indexRates(domain.PublishedPricing()) }

func TestClassify_MatchesFamilyByName(t *testing.T) {
	rates := bundledRates()
	cases := []struct {
		model string
		want  domain.ModelPricing
	}{
		{"claude-opus-4-7", rates["opus"]},
		{"claude-3-5-sonnet-20241022", rates["sonnet"]},
		{"claude-haiku-4-5", rates["haiku"]},
		// Unknown families fall back to zero rates.
		{"claude-instant-1.2", domain.ModelPricing{}},
		{"", domain.ModelPricing{}},
	}
	for _, c := range cases {
		got := rates.classify(c.model)
		if got != c.want {
			t.Errorf("classify(%q) = %+v, want %+v", c.model, got, c.want)
		}
	}
}

func TestEstimateCostUSD_OpusRates(t *testing.T) {
	rates := bundledRates()
	u := &usageBlock{
		InputTokens:   1_000_000,
		OutputTokens:  1_000_000,
		CacheCreation: 1_000_000,
		CacheRead:     1_000_000,
	}
	// At 1M tokens each, opus cost = input(15) + output(75) + cacheWrite(18.75) + cacheRead(1.50).
	want := 15.00 + 75.00 + 18.75 + 1.50
	got := rates.estimateCostUSD("claude-opus-4-7", u)
	if !approxEqual(got, want) {
		t.Fatalf("opus cost = %v, want %v", got, want)
	}
}

func TestEstimateCostUSD_ZeroForUnknownModel(t *testing.T) {
	rates := bundledRates()
	u := &usageBlock{InputTokens: 1_000_000, OutputTokens: 1_000_000}
	if got := rates.estimateCostUSD("claude-future-tier", u); !approxEqual(got, 0) {
		t.Fatalf("unknown-model cost = %v, want 0 (unknown fallback)", got)
	}
}

func TestEstimateCostUSD_AppliesPassedRates(t *testing.T) {
	// Runtime pricing refresh path: rates come from PricingProvider, not from
	// the bundled domain.PublishedPricing(). Verify the index honours them.
	custom := indexRates([]domain.ModelPricing{
		{Family: "opus", Input: 1, Output: 1, CacheWrite: 1, CacheRead: 1},
	})
	u := &usageBlock{InputTokens: 1_000_000, OutputTokens: 1_000_000}
	want := 2.0 // 1M input * $1 + 1M output * $1 = $2
	got := custom.estimateCostUSD("claude-opus-4-7", u)
	if !approxEqual(got, want) {
		t.Fatalf("custom-rates cost = %v, want %v", got, want)
	}
}
