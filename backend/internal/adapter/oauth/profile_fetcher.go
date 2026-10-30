package oauth

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

const profileURL = "https://api.anthropic.com/api/oauth/profile"

// ProfileFetcher asks Anthropic whose login an access token is. A token
// file says nothing about its owner, and ~/.claude.json can name a
// different account than the token Claude Code actually holds.
type ProfileFetcher struct {
	hc *http.Client
}

// NewProfileFetcher returns a fetcher with the usage fetcher's timeout.
func NewProfileFetcher() *ProfileFetcher {
	return &ProfileFetcher{hc: &http.Client{Timeout: fetchTimeout}}
}

// Identity returns the account email and organization UUID of the token.
func (f *ProfileFetcher) Identity(ctx context.Context, accessToken string) (*domain.TokenIdentity, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, profileURL, nil)
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
		return nil, fmt.Errorf("profile api %d", resp.StatusCode)
	}
	return parseProfile(raw)
}

func parseProfile(raw []byte) (*domain.TokenIdentity, error) {
	var out struct {
		Account struct {
			Email string `json:"email"`
		} `json:"account"`
		Organization struct {
			UUID string `json:"uuid"`
		} `json:"organization"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	if out.Account.Email == "" {
		return nil, fmt.Errorf("profile api: no account email")
	}
	return &domain.TokenIdentity{Email: out.Account.Email, OrgUUID: out.Organization.UUID}, nil
}
