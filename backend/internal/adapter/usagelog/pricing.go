package usagelog

import (
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// rateIndex is a lowercased family→rate lookup built once per Scan from the
// rates passed in by the usecase (PricingProvider). Built per-scan rather
// than cached so a runtime pricing refresh takes effect on the next report
// without a service restart.
type rateIndex map[string]domain.ModelPricing

func indexRates(rates []domain.ModelPricing) rateIndex {
	out := make(rateIndex, len(rates))
	for _, r := range rates {
		out[strings.ToLower(r.Family)] = r
	}
	return out
}

// classify returns the pricing family for a model string. Unknown models
// (e.g. "claude-instant", a future tier we haven't priced yet) get zero
// rates rather than blowing up — the cost column simply under-reports.
func (r rateIndex) classify(model string) domain.ModelPricing {
	m := strings.ToLower(model)
	for family, price := range r {
		if strings.Contains(m, family) {
			return price
		}
	}
	return domain.ModelPricing{}
}

// estimateCostUSD computes the dollar cost for one assistant message's
// usage block at the resolved model's published rate.
func (r rateIndex) estimateCostUSD(model string, u *usageBlock) float64 {
	p := r.classify(model)
	return (float64(u.InputTokens)*p.Input +
		float64(u.OutputTokens)*p.Output +
		float64(u.CacheCreation)*p.CacheWrite +
		float64(u.CacheRead)*p.CacheRead) / 1_000_000
}
