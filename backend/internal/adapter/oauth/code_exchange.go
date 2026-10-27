package oauth

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Browser sign-in for a new account (the Claude Code CLI's own flow). The
// authorize page ends on the manual-code callback, which shows
// "<code>#<state>" for the user to copy back into the app. Same URLs as the
// Claude Code CLI's CLAUDE_AI_AUTHORIZE_URL / MANUAL_REDIRECT_URL (it moved
// off console.anthropic.com).
const (
	authorizeURL = "https://claude.com/cai/oauth/authorize"
	redirectURI  = "https://platform.claude.com/oauth/code/callback"
	loginScope   = "org:create_api_key user:profile user:inference"
)

// LoginAttempt is one sign-in's PKCE verifier and anti-CSRF state. Each
// attempt is fresh so two concurrent sign-ins never share a pair.
type LoginAttempt struct {
	URL      string `json:"url"`
	State    string `json:"state"`
	Verifier string `json:"verifier"`
}

// NewLoginAttempt builds the authorize URL for a new sign-in.
func NewLoginAttempt() (*LoginAttempt, error) {
	verifier, err := randomURLSafe(48)
	if err != nil {
		return nil, err
	}
	state, err := randomURLSafe(24)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256([]byte(verifier))
	q := url.Values{
		"code":                  {"true"},
		"client_id":             {clientID},
		"response_type":         {"code"},
		"redirect_uri":          {redirectURI},
		"scope":                 {loginScope},
		"code_challenge":        {base64.RawURLEncoding.EncodeToString(sum[:])},
		"code_challenge_method": {"S256"},
		"state":                 {state},
	}
	return &LoginAttempt{URL: authorizeURL + "?" + q.Encode(), State: state, Verifier: verifier}, nil
}

func randomURLSafe(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// SplitPastedCode accepts what the callback page shows ("code#state") or a
// bare code, and rejects a code issued for a different sign-in attempt.
func SplitPastedCode(pasted, wantState string) (string, error) {
	pasted = strings.TrimSpace(pasted)
	code, state, hasState := strings.Cut(pasted, "#")
	code = strings.TrimSpace(code)
	if code == "" {
		return "", errors.New("the sign-in code is empty")
	}
	if hasState && strings.TrimSpace(state) != wantState {
		return "", errors.New("this code belongs to a different sign-in — start again and paste the newest code")
	}
	return code, nil
}

// SignedIn is a token-exchange result. Identity comes from the response's
// account/organization objects: the access token is opaque.
type SignedIn struct {
	AccessToken      string
	RefreshToken     string
	ExpiresAt        int64
	Scopes           []string
	Email            string
	OrgUUID          string
	OrganizationName string
}

// ExchangeCode trades an authorization code for tokens. state is required by
// the endpoint (400 "Invalid request format" without it).
func ExchangeCode(ctx context.Context, code, state, verifier string) (*SignedIn, error) {
	body, _ := json.Marshal(map[string]string{
		"grant_type":    "authorization_code",
		"code":          code,
		"state":         state,
		"code_verifier": verifier,
		"client_id":     clientID,
		"redirect_uri":  redirectURI,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, tokenURL, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", userAgent)

	resp, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		if containsAuthFailureCode(string(raw)) {
			return nil, errors.New("the sign-in code was rejected (expired or already used) — start again")
		}
		return nil, fmt.Errorf("oauth code exchange %d: %s", resp.StatusCode, truncateBody(raw))
	}
	var out struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int64  `json:"expires_in"`
		Scope        string `json:"scope"`
		Account      struct {
			EmailAddress string `json:"email_address"`
		} `json:"account"`
		Organization struct {
			UUID string `json:"uuid"`
			Name string `json:"name"`
		} `json:"organization"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("oauth code exchange: %w", err)
	}
	if out.AccessToken == "" || out.RefreshToken == "" {
		return nil, errors.New("oauth code exchange: no usable token pair")
	}
	if out.ExpiresIn == 0 {
		out.ExpiresIn = 3600
	}
	scope := out.Scope
	if scope == "" {
		scope = loginScope
	}
	return &SignedIn{
		AccessToken:      out.AccessToken,
		RefreshToken:     out.RefreshToken,
		ExpiresAt:        time.Now().UnixMilli() + out.ExpiresIn*1000,
		Scopes:           splitScopes(scope),
		Email:            out.Account.EmailAddress,
		OrgUUID:          out.Organization.UUID,
		OrganizationName: out.Organization.Name,
	}, nil
}

func truncateBody(raw []byte) string {
	if len(raw) > 200 {
		return string(raw[:200]) + "…"
	}
	return string(raw)
}
