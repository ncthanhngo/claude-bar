// Package oauth implements the TokenRefresher and UsageFetcher ports against
// Anthropic's Claude Code OAuth endpoints.
package oauth

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

const (
	tokenURL           = "https://platform.claude.com/v1/oauth/token"
	clientID           = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
	userAgent          = "claude-swap-widget/0.1"
	expiryBufferMillis = 5 * 60 * 1000
)

// TokenRefresher exchanges a refresh_token for a fresh access_token.
type TokenRefresher struct {
	hc *http.Client
}

// NewTokenRefresher returns a refresher with a 10s timeout.
func NewTokenRefresher() *TokenRefresher {
	return &TokenRefresher{hc: &http.Client{Timeout: 10 * time.Second}}
}

// Refresh calls the OAuth token endpoint and returns a new payload.
func (r *TokenRefresher) Refresh(ctx context.Context, refreshToken string) (*domain.OAuthPayload, error) {
	body, _ := json.Marshal(map[string]string{
		"grant_type":    "refresh_token",
		"refresh_token": refreshToken,
		"client_id":     clientID,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, tokenURL, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", userAgent)

	resp, err := r.hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode == http.StatusTooManyRequests {
		return nil, &RateLimitedError{RetryAfter: resp.Header.Get("Retry-After")}
	}
	if resp.StatusCode >= 400 {
		// Permanent auth failure: server explicitly rejected the grant. Only
		// 400/401 with an "invalid_grant" or "invalid_token" body qualify —
		// everything else (500, unexpected 4xx) is treated as transient so we
		// never false-positive on infra blips.
		if resp.StatusCode == http.StatusBadRequest || resp.StatusCode == http.StatusUnauthorized {
			body := string(raw)
			if containsAuthFailureCode(body) {
				return nil, &InvalidGrantError{Body: body}
			}
		}
		return nil, fmt.Errorf("oauth refresh %d: %s", resp.StatusCode, string(raw))
	}
	var out struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int64  `json:"expires_in"`
		Scope        string `json:"scope"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	if out.AccessToken == "" {
		return nil, errors.New("oauth refresh: empty access_token")
	}
	now := time.Now().UnixMilli()
	p := &domain.OAuthPayload{
		AccessToken:  out.AccessToken,
		RefreshToken: out.RefreshToken,
		ExpiresAt:    now + out.ExpiresIn*1000,
	}
	if p.RefreshToken == "" {
		p.RefreshToken = refreshToken
	}
	if out.Scope != "" {
		p.Scopes = splitScopes(out.Scope)
	}
	return p, nil
}

// IsExpired returns true if the token is past or near expiry.
func IsExpired(expiresAtMillis int64) bool {
	if expiresAtMillis == 0 {
		return false
	}
	return time.Now().UnixMilli()+expiryBufferMillis >= expiresAtMillis
}

// InvalidGrantError is returned by Refresh when the server definitively rejects
// the grant (HTTP 400/401 with an "invalid_grant" or "invalid_token" body).
// It is distinct from transient failures (rate-limit, network, 5xx) so callers
// can take remediation action — e.g. prompting the user to re-login — without
// false-positiving on temporary outages.
type InvalidGrantError struct{ Body string }

func (e *InvalidGrantError) Error() string {
	return "oauth refresh: invalid grant — " + e.Body
}

// IsDefinitiveAuthFailure reports whether err represents a permanent credential
// rejection: an InvalidGrantError from the token endpoint, or an
// UnauthorizedError (401) from the usage API on a non-expired token.
//
// Conservative by design: only types with a clear permanent-rejection semantic
// return true. RateLimitedError, network errors, and unknown errors all return
// false so callers err toward "transient" and avoid disrupting active sessions.
func IsDefinitiveAuthFailure(err error) bool {
	if err == nil {
		return false
	}
	var ig *InvalidGrantError
	if errors.As(err, &ig) {
		return true
	}
	var ua *UnauthorizedError
	return errors.As(err, &ua)
}

// containsAuthFailureCode checks whether the raw response body signals a
// permanent credential rejection. Matches "invalid_grant" and "invalid_token"
// as substrings; this is intentionally loose (avoids dependency on the exact
// JSON key) but conservative (requires the literal strings Anthropic uses).
func containsAuthFailureCode(body string) bool {
	return contains(body, "invalid_grant") || contains(body, "invalid_token")
}

// contains is a simple substring check without importing strings to keep
// dependencies minimal — only called during error handling.
func contains(s, substr string) bool {
	if len(substr) > len(s) {
		return false
	}
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

func splitScopes(s string) []string {
	if s == "" {
		return nil
	}
	out := []string{}
	cur := ""
	for _, c := range s {
		if c == ' ' {
			if cur != "" {
				out = append(out, cur)
				cur = ""
			}
			continue
		}
		cur += string(c)
	}
	if cur != "" {
		out = append(out, cur)
	}
	return out
}
