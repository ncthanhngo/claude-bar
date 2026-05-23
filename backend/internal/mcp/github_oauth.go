package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	githubAuthURL  = "https://github.com/login/oauth/authorize"
	githubTokenURL = "https://github.com/login/oauth/access_token"
	githubAPIBase  = "https://api.github.com"
	// Scopes the OAuth App requests. Read uses `repo` (full repo metadata +
	// private read); write uses the same scope — GitHub merges read+write
	// into `repo`. No `admin:*`, no `delete_repo`, no `workflow`.
	githubScope = "repo"
)

// githubTokenURLForTest lets tests redirect token endpoints to httptest.
var (
	githubAuthURLForTest  = ""
	githubTokenURLForTest = ""
	githubAPIBaseForTest  = ""
)

func githubAuthEndpoint() string {
	if githubAuthURLForTest != "" {
		return githubAuthURLForTest
	}
	return githubAuthURL
}
func githubTokenEndpoint() string {
	if githubTokenURLForTest != "" {
		return githubTokenURLForTest
	}
	return githubTokenURL
}
func githubAPIEndpoint() string {
	if githubAPIBaseForTest != "" {
		return githubAPIBaseForTest
	}
	return githubAPIBase
}

// GitHubOAuthResult carries the persisted payload back to the connect command.
type GitHubOAuthResult struct {
	Payload *GitHubPayload
	Login   string
}

// GitHubStartOAuth runs the loopback PKCE+state flow against GitHub's OAuth
// App endpoints. clientSecret is required by GitHub's OAuth App token
// exchange (PKCE alone is not accepted on github.com today — PKCE is still
// applied so any future support drops in cleanly, but the secret remains the
// load-bearing credential and must be shipped with the app installer).
//
// PKCE + state per Red-Team Finding 7. The callback rejects mismatched Host
// headers and non-127.0.0.1 sources.
func GitHubStartOAuth(ctx context.Context, clientID, clientSecret string, openBrowser func(string) error) (*GitHubOAuthResult, error) {
	if strings.TrimSpace(clientID) == "" {
		return nil, fmt.Errorf("github: client-id required")
	}
	if strings.TrimSpace(clientSecret) == "" {
		return nil, fmt.Errorf("github: client-secret required (OAuth Apps cannot exchange code without it)")
	}
	verifier, challenge, err := newPKCE()
	if err != nil {
		return nil, err
	}
	state, err := randomString(32)
	if err != nil {
		return nil, err
	}

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("loopback listen: %w", err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	expectedHost := fmt.Sprintf("127.0.0.1:%d", port)
	redirectURI := "http://" + expectedHost + "/callback"

	codeCh := make(chan string, 1)
	errCh := make(chan error, 1)

	mux := http.NewServeMux()
	mux.HandleFunc("/callback", func(w http.ResponseWriter, r *http.Request) {
		// Host header must match the loopback we advertised — defence against
		// rebinding / cross-origin callback forgery.
		if r.Host != expectedHost {
			http.Error(w, "host mismatch", http.StatusBadRequest)
			errCh <- fmt.Errorf("oauth: host mismatch %q", r.Host)
			return
		}
		q := r.URL.Query()
		if got := q.Get("state"); got != state {
			http.Error(w, "state mismatch", http.StatusBadRequest)
			errCh <- fmt.Errorf("oauth state mismatch")
			return
		}
		if errStr := q.Get("error"); errStr != "" {
			http.Error(w, errStr, http.StatusBadRequest)
			errCh <- fmt.Errorf("oauth: %s", errStr)
			return
		}
		code := q.Get("code")
		if code == "" {
			http.Error(w, "missing code", http.StatusBadRequest)
			errCh <- fmt.Errorf("oauth: missing code")
			return
		}
		fmt.Fprintln(w, "GitHub connected. You may close this tab.")
		codeCh <- code
	})
	srv := &http.Server{
		Handler:        mux,
		ReadTimeout:    30 * time.Second,
		WriteTimeout:   30 * time.Second,
		MaxHeaderBytes: 4096,
	}
	go func() { _ = srv.Serve(listener) }()
	defer srv.Shutdown(context.Background())

	consent := githubAuthEndpoint() + "?" + url.Values{
		"client_id":             {clientID},
		"redirect_uri":          {redirectURI},
		"response_type":         {"code"},
		"scope":                 {githubScope},
		"state":                 {state},
		"code_challenge":        {challenge},
		"code_challenge_method": {"S256"},
		"allow_signup":          {"false"},
	}.Encode()
	if err := openBrowser(consent); err != nil {
		return nil, fmt.Errorf("open browser: %w", err)
	}

	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case err := <-errCh:
		return nil, err
	case code := <-codeCh:
		return githubExchangeCode(ctx, clientID, clientSecret, code, verifier, redirectURI)
	case <-time.After(5 * time.Minute):
		return nil, fmt.Errorf("oauth timeout")
	}
}

func githubExchangeCode(ctx context.Context, clientID, clientSecret, code, verifier, redirectURI string) (*GitHubOAuthResult, error) {
	form := url.Values{
		"client_id":     {clientID},
		"client_secret": {clientSecret},
		"code":          {code},
		"code_verifier": {verifier},
		"redirect_uri":  {redirectURI},
	}
	tokens, err := githubPostTokenForm(ctx, form)
	if err != nil {
		return nil, err
	}
	if tokens.AccessToken == "" {
		return nil, fmt.Errorf("github: token exchange returned no access_token")
	}
	payload := &GitHubPayload{
		ClientID:     clientID,
		ClientSecret: clientSecret,
		AccessToken:  tokens.AccessToken,
		RefreshToken: tokens.RefreshToken,
		Scope:        tokens.Scope,
	}
	if tokens.ExpiresIn > 0 {
		payload.AccessExpiresAt = time.Now().Add(time.Duration(tokens.ExpiresIn) * time.Second).Add(-1 * time.Minute)
	}
	if tokens.RefreshTokenExpiresIn > 0 {
		payload.RefreshExpiresAt = time.Now().Add(time.Duration(tokens.RefreshTokenExpiresIn) * time.Second)
	}
	return &GitHubOAuthResult{Payload: payload}, nil
}

// githubRefresh ensures the cached access token is fresh, refreshing via the
// stored refresh token when it has expired. OAuth Apps without rotation
// (classic) simply return the existing token.
func (g *Gateway) githubRefresh(ctx context.Context, cc *CallContext) (string, error) {
	payload, err := UnmarshalGitHubPayload(cc.Payload)
	if err != nil {
		return "", fmt.Errorf("decode github payload: %w", err)
	}
	if payload.AccessToken != "" && (payload.AccessExpiresAt.IsZero() || time.Now().Before(payload.AccessExpiresAt)) {
		return payload.AccessToken, nil
	}
	if payload.RefreshToken == "" {
		// Classic OAuth Apps — token never rotates. Surface stale token; tools
		// will receive 401 and the user will be prompted to re-auth.
		return payload.AccessToken, nil
	}
	form := url.Values{
		"client_id":     {payload.ClientID},
		"client_secret": {payload.ClientSecret},
		"grant_type":    {"refresh_token"},
		"refresh_token": {payload.RefreshToken},
	}
	tokens, err := githubPostTokenForm(ctx, form)
	if err != nil {
		return "", err
	}
	payload.AccessToken = tokens.AccessToken
	if tokens.RefreshToken != "" {
		payload.RefreshToken = tokens.RefreshToken
	}
	if tokens.ExpiresIn > 0 {
		payload.AccessExpiresAt = time.Now().Add(time.Duration(tokens.ExpiresIn) * time.Second).Add(-1 * time.Minute)
	}
	updated, mErr := payload.Marshal()
	if mErr == nil {
		_ = g.Resolver.Secrets.Write(ctx, cc.AccountNumber, cc.Service, updated)
	}
	return payload.AccessToken, nil
}

type githubTokenResponse struct {
	AccessToken           string `json:"access_token"`
	RefreshToken          string `json:"refresh_token"`
	ExpiresIn             int    `json:"expires_in"`
	RefreshTokenExpiresIn int    `json:"refresh_token_expires_in"`
	Scope                 string `json:"scope"`
	TokenType             string `json:"token_type"`
	Error                 string `json:"error"`
	ErrorDescription      string `json:"error_description"`
}

func githubPostTokenForm(ctx context.Context, form url.Values) (*githubTokenResponse, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, githubTokenEndpoint(), strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("token http: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("token http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body))))
	}
	var t githubTokenResponse
	if err := json.Unmarshal(body, &t); err != nil {
		return nil, fmt.Errorf("token decode: %w", err)
	}
	if t.Error != "" {
		return nil, fmt.Errorf("github oauth: %s: %s", t.Error, Redact(t.ErrorDescription))
	}
	return &t, nil
}
