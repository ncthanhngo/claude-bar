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
