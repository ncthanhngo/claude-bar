package oauth

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

const (
	usageURL    = "https://api.anthropic.com/api/oauth/usage"
	betaHeader  = "oauth-2025-04-20"
	fetchTimeout = 5 * time.Second
)

// UsageFetcher calls the Anthropic OAuth usage endpoint.
type UsageFetcher struct {
	hc *http.Client
}

// NewUsageFetcher returns a fetcher with a 5s timeout.
func NewUsageFetcher() *UsageFetcher {
	return &UsageFetcher{hc: &http.Client{Timeout: fetchTimeout}}
}

// Fetch returns usage windows for the bearer token. Returns nil if the API
// returns 401 (caller should refresh and retry) or unsupported response.
func (f *UsageFetcher) Fetch(ctx context.Context, accessToken string) (*domain.Usage, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, usageURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("anthropic-beta", betaHeader)
	req.Header.Set("User-Agent", userAgent)

	resp, err := f.hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode == http.StatusUnauthorized {
		return nil, &UnauthorizedError{Body: string(raw)}
	}
	if resp.StatusCode == http.StatusTooManyRequests {
		return nil, &RateLimitedError{RetryAfter: resp.Header.Get("Retry-After")}
	}
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("usage api %d", resp.StatusCode)
	}
	var apiResp struct {
		FiveHour *windowDTO `json:"five_hour"`
		SevenDay *windowDTO `json:"seven_day"`
	}
	if err := json.Unmarshal(raw, &apiResp); err != nil {
		return nil, err
	}
	u := &domain.Usage{FetchedAt: time.Now().UTC()}
	if apiResp.FiveHour != nil {
		u.FiveHour = apiResp.FiveHour.toDomain()
	}
	if apiResp.SevenDay != nil {
		u.SevenDay = apiResp.SevenDay.toDomain()
	}
	return u, nil
}

type windowDTO struct {
	Utilization float64 `json:"utilization"`
	ResetsAt    string  `json:"resets_at"`
}

func (w *windowDTO) toDomain() *domain.Window {
	t, _ := time.Parse(time.RFC3339, w.ResetsAt)
	return &domain.Window{UtilizationPct: w.Utilization, ResetsAt: t.UTC()}
}

// UnauthorizedError signals the caller should refresh and retry.
type UnauthorizedError struct{ Body string }

func (e *UnauthorizedError) Error() string {
	return "usage api 401: " + e.Body
}

// RateLimitedError carries the optional Retry-After header value (seconds).
// When the server omits the header, RetryAfter is empty and Error() renders
// an approximate fallback ("~60s") so users always see a wait hint.
type RateLimitedError struct{ RetryAfter string }

// defaultRetryAfterSec is the conservative fallback used when Anthropic omits
// the Retry-After header on a 429. 60s matches common OAuth provider windows
// and is short enough that retry guidance stays actionable.
const defaultRetryAfterSec = "60"

func (e *RateLimitedError) Error() string {
	if e.RetryAfter != "" {
		return "rate limited (retry after " + e.RetryAfter + "s)"
	}
	return "rate limited (retry after ~" + defaultRetryAfterSec + "s)"
}
