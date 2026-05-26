package mcp

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

const (
	gdriveAuthURL  = "https://accounts.google.com/o/oauth2/v2/auth"
	gdriveTokenURL = "https://oauth2.googleapis.com/token"
	// Existing Google connectors only need read scopes; cb_gsheets_*
	// (added for the markdown-table → Google Sheet use case) needs
	// write access to spreadsheets. Bundling all four in one scope set
	// means there is still exactly one OAuth flow per Google account —
	// the user re-runs Connect once to upgrade an existing v11 token,
	// then every Google tool works against the upgraded grant. The
	// `spreadsheets` scope is the narrowest one that allows both
	// creating new sheets and writing cells into existing ones.
	gdriveScope = "https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/calendar.events.readonly https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/spreadsheets"
)

// tokenURLForTest is overridden by tests pointing at httptest. Production
// code reads this via tokenURL(), which defaults to gdriveTokenURL.
var tokenURLForTest = ""

func tokenURL() string {
	if tokenURLForTest != "" {
		return tokenURLForTest
	}
	return gdriveTokenURL
}

// GDriveOAuthResult is what the loopback PKCE flow returns to the caller.
type GDriveOAuthResult struct {
	Payload *GDrivePayload
	Email   string
}

// GDriveStartOAuth runs the loopback PKCE flow:
//  1. starts a localhost listener on a random port
//  2. opens the user's browser at Google's consent URL
//  3. waits for the redirect with ?code=...
//  4. exchanges the code for refresh+access tokens
//
// clientID is the OAuth client ID of the Claude Bar installed app.
// clientSecret is optional in the OAuth spec, but Google Desktop clients can
// require it for token exchange/refresh. If supplied, it is stored in Keychain.
// openBrowser is called with the consent URL; the caller can shell out to `open`.
func GDriveStartOAuth(ctx context.Context, clientID, clientSecret string, openBrowser func(string) error) (*GDriveOAuthResult, error) {
	verifier, challenge, err := newPKCE()
	if err != nil {
		return nil, err
	}
	state, err := randomString(16)
	if err != nil {
		return nil, err
	}

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("loopback listen: %w", err)
	}
	redirectURI := fmt.Sprintf("http://127.0.0.1:%d/callback", listener.Addr().(*net.TCPAddr).Port)

	codeCh := make(chan string, 1)
	errCh := make(chan error, 1)
	srv := &http.Server{
		ReadTimeout:    30 * time.Second,
		WriteTimeout:   30 * time.Second,
		MaxHeaderBytes: 4096,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/callback" {
			http.NotFound(w, r)
			return
		}
		if got := r.URL.Query().Get("state"); got != state {
			http.Error(w, "state mismatch", http.StatusBadRequest)
			errCh <- fmt.Errorf("oauth state mismatch")
			return
		}
		if errStr := r.URL.Query().Get("error"); errStr != "" {
			http.Error(w, errStr, http.StatusBadRequest)
			errCh <- fmt.Errorf("oauth: %s", errStr)
			return
		}
		code := r.URL.Query().Get("code")
		if code == "" {
			http.Error(w, "missing code", http.StatusBadRequest)
			errCh <- fmt.Errorf("oauth: missing code")
			return
		}
		fmt.Fprintln(w, "Google Drive connected. You may close this tab.")
		codeCh <- code
	}),
	}
	go func() { _ = srv.Serve(listener) }()
	defer srv.Shutdown(context.Background())

	consent := gdriveAuthURL + "?" + url.Values{
		"client_id":             {clientID},
		"redirect_uri":          {redirectURI},
		"response_type":         {"code"},
		"scope":                 {gdriveScope},
		"access_type":           {"offline"},
		"prompt":                {"consent"},
		"state":                 {state},
		"code_challenge":        {challenge},
		"code_challenge_method": {"S256"},
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
		return exchangeCode(ctx, clientID, clientSecret, code, verifier, redirectURI)
	case <-time.After(5 * time.Minute):
		return nil, fmt.Errorf("oauth timeout")
	}
}

func exchangeCode(ctx context.Context, clientID, clientSecret, code, verifier, redirectURI string) (*GDriveOAuthResult, error) {
	form := url.Values{
		"client_id":     {clientID},
		"code":          {code},
		"code_verifier": {verifier},
		"grant_type":    {"authorization_code"},
		"redirect_uri":  {redirectURI},
	}
	if clientSecret != "" {
		form.Set("client_secret", clientSecret)
	}
	tokens, err := postTokenForm(ctx, form)
	if err != nil {
		return nil, err
	}
	if tokens.RefreshToken == "" {
		return nil, fmt.Errorf("oauth: missing refresh_token (revoke previous grant and retry)")
	}
	return &GDriveOAuthResult{
		Payload: &GDrivePayload{
			ClientID:        clientID,
			ClientSecret:    clientSecret,
			RefreshToken:    tokens.RefreshToken,
			AccessToken:     tokens.AccessToken,
			AccessExpiresAt: time.Now().Add(time.Duration(tokens.ExpiresIn) * time.Second).Add(-1 * time.Minute),
			Scope:           tokens.Scope,
		},
	}, nil
}

// gdriveRefresh returns a fresh access token, using the cached one if it is
// still valid. Persists the refreshed token back to the secret store.
func (g *Gateway) gdriveRefresh(ctx context.Context, cc *CallContext) (string, error) {
	payload, err := UnmarshalGDrivePayload(cc.Payload)
	if err != nil {
		return "", fmt.Errorf("decode gdrive payload: %w", err)
	}
	access, updated, err := RefreshGDriveAccessToken(ctx, payload)
	if err != nil {
		return "", err
	}
	if updated != nil {
		if marshalled, mErr := updated.Marshal(); mErr == nil {
			if werr := g.Resolver.Secrets.Write(ctx, cc.AccountNumber, cc.Service, marshalled); werr != nil {
				// Refresh succeeded but we couldn't persist the new access token.
				// Token in memory is still valid for this call; next call will
				// trigger another refresh round-trip. Log redacted, never panic.
				fmt.Fprintln(os.Stderr, "claude-bar-mcp gdrive: persist refreshed token failed:", Redact(werr.Error()))
			}
		}
	}
	return access, nil
}

// RefreshGDriveAccessToken is the Gateway-free version of token refresh —
// callers outside the running gateway (CLI reconnect flow, tests) reuse it
// to swap a refresh token for a fresh access token without instantiating a
// full Gateway+Resolver stack.
//
// Returns (accessToken, updatedPayload, err). updatedPayload is non-nil
// only when a network round-trip happened; callers persist it via their
// own MCPSecrets.Write so the next call doesn't re-refresh. When the
// cached access token in `payload` is still valid, the function returns
// (payload.AccessToken, nil, nil) — no persist required.
func RefreshGDriveAccessToken(ctx context.Context, payload *GDrivePayload) (string, *GDrivePayload, error) {
	if payload == nil {
		return "", nil, fmt.Errorf("nil gdrive payload")
	}
	if payload.AccessToken != "" && time.Now().Before(payload.AccessExpiresAt) {
		return payload.AccessToken, nil, nil
	}
	form := url.Values{
		"client_id":     {payload.ClientID},
		"refresh_token": {payload.RefreshToken},
		"grant_type":    {"refresh_token"},
	}
	if payload.ClientSecret != "" {
		form.Set("client_secret", payload.ClientSecret)
	}
	tokens, err := postTokenForm(ctx, form)
	if err != nil {
		return "", nil, err
	}
	payload.AccessToken = tokens.AccessToken
	payload.AccessExpiresAt = time.Now().Add(time.Duration(tokens.ExpiresIn) * time.Second).Add(-1 * time.Minute)
	return payload.AccessToken, payload, nil
}

type tokenResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int    `json:"expires_in"`
	Scope        string `json:"scope"`
	TokenType    string `json:"token_type"`
}

func postTokenForm(ctx context.Context, form url.Values) (*tokenResponse, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, tokenURL(), strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
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
	var t tokenResponse
	if err := json.Unmarshal(body, &t); err != nil {
		return nil, fmt.Errorf("token decode: %w", err)
	}
	return &t, nil
}

func newPKCE() (verifier, challenge string, err error) {
	verifier, err = randomString(64)
	if err != nil {
		return "", "", err
	}
	sum := sha256.Sum256([]byte(verifier))
	challenge = base64.RawURLEncoding.EncodeToString(sum[:])
	return verifier, challenge, nil
}

func randomString(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b)[:n], nil
}
