package mcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// VerifyResult is what each per-service Verify* returns to the use-case
// layer so it can populate metadata honestly (DisplayName, Account, Scopes).
type VerifyResult struct {
	DisplayName string
	Account     string
	Scopes      []string
}

// VerifySlackToken checks the token against the Slack endpoints our MCP tools
// actually call. auth.test alone accepts bot tokens, but search.messages does
// not, so a bot token would otherwise appear connected and fail later.
func VerifySlackToken(ctx context.Context, httpClient *http.Client, token string) (*VerifyResult, error) {
	return verifySlackAt(ctx, httpClient, slackAPIBase, token)
}

func verifySlackAt(ctx context.Context, httpClient *http.Client, base, token string) (*VerifyResult, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/auth.test", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("slack verify: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("slack verify http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body))))
	}
	var out struct {
		OK     bool   `json:"ok"`
		Error  string `json:"error"`
		Team   string `json:"team"`
		User   string `json:"user"`
		TeamID string `json:"team_id"`
		UserID string `json:"user_id"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("slack verify decode: %w", err)
	}
	if !out.OK {
		return nil, fmt.Errorf("slack verify: %s", out.Error)
	}
	if strings.HasPrefix(token, "xoxb-") {
		return nil, errors.New("slack verify: bot tokens (xoxb-) cannot use search.messages; use a Slack user token (xoxp- or xoxe-) with search:read and channel read/history scopes")
	}
	if err := verifySlackCapability(ctx, httpClient, base, token, "conversations.list", "types=public_channel,private_channel&limit=1&exclude_archived=true"); err != nil {
		return nil, fmt.Errorf("slack verify conversations.list: %w", err)
	}
	if err := verifySlackCapability(ctx, httpClient, base, token, "search.messages", "query=the&count=1"); err != nil {
		return nil, fmt.Errorf("slack verify search.messages: %w", err)
	}
	return &VerifyResult{DisplayName: out.Team, Account: out.User}, nil
}

func verifySlackCapability(ctx context.Context, httpClient *http.Client, base, token, method, rawQuery string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/"+method+"?"+rawQuery, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("slack verify: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body))))
	}
	var out slackResponse
	if err := json.Unmarshal(body, &out); err != nil {
		return fmt.Errorf("decode: %w", err)
	}
	if !out.OK {
		return errors.New(out.Error)
	}
	return nil
}

// VerifyClickUpToken pings ClickUp's /user endpoint. The personal token is
// sent raw in Authorization (no Bearer), matching how ClickUp documents it.
func VerifyClickUpToken(ctx context.Context, httpClient *http.Client, token string) (*VerifyResult, error) {
	return verifyClickUpAt(ctx, httpClient, clickupAPIBase, token)
}

func verifyClickUpAt(ctx context.Context, httpClient *http.Client, base, token string) (*VerifyResult, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/user", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", token)
	req.Header.Set("Accept", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("clickup verify: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode == http.StatusUnauthorized {
		return nil, errors.New("clickup verify: token unauthorized")
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("clickup verify http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body))))
	}
	var out struct {
		User struct {
			ID    int    `json:"id"`
			Email string `json:"email"`
			Name  string `json:"username"`
		} `json:"user"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("clickup verify decode: %w", err)
	}
	if out.User.ID == 0 {
		return nil, errors.New("clickup verify: unexpected empty user")
	}
	return &VerifyResult{DisplayName: out.User.Name, Account: out.User.Email}, nil
}

// VerifyGDriveAccess uses a freshly issued access token to call Drive's
// /about endpoint. Confirms scope contains drive.readonly and returns the
// user's email for display.
func VerifyGDriveAccess(ctx context.Context, httpClient *http.Client, accessToken string) (*VerifyResult, error) {
	return verifyGDriveAt(ctx, httpClient, gdriveAPIBase, accessToken)
}

func verifyGDriveAt(ctx context.Context, httpClient *http.Client, base, accessToken string) (*VerifyResult, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/about?fields=user(emailAddress,displayName)", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Accept", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("gdrive verify: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("gdrive verify http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body))))
	}
	var out struct {
		User struct {
			EmailAddress string `json:"emailAddress"`
			DisplayName  string `json:"displayName"`
		} `json:"user"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("gdrive verify decode: %w", err)
	}
	return &VerifyResult{DisplayName: out.User.DisplayName, Account: out.User.EmailAddress}, nil
}

// VerifyGitHubToken pings GitHub's /user endpoint with the supplied token
// and returns the login + name for display. Accepts classic PATs (ghp_…),
// fine-grained PATs (github_pat_…), and OAuth user-to-server tokens
// (gho_…) — the API treats all three the same as `Authorization: Bearer`.
//
// When the response carries an `X-OAuth-Scopes` header (classic PAT or
// OAuth App) we surface those scopes back to the caller so the registry
// records what the user actually granted. Fine-grained PATs omit the
// header — that is normal and not an error; tool calls will surface a
// 403 if the PAT lacks the required permission.
func VerifyGitHubToken(ctx context.Context, httpClient *http.Client, token string) (*VerifyResult, error) {
	return verifyGitHubAt(ctx, httpClient, githubAPIEndpoint(), token)
}

func verifyGitHubAt(ctx context.Context, httpClient *http.Client, base, token string) (*VerifyResult, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/user", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("github verify: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode == http.StatusUnauthorized {
		return nil, errors.New("github verify: token unauthorized")
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("github verify http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body))))
	}
	var out struct {
		Login string `json:"login"`
		Name  string `json:"name"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("github verify decode: %w", err)
	}
	if out.Login == "" {
		return nil, errors.New("github verify: unexpected empty login")
	}
	var scopes []string
	if h := strings.TrimSpace(resp.Header.Get("X-OAuth-Scopes")); h != "" {
		for _, s := range strings.Split(h, ",") {
			if s = strings.TrimSpace(s); s != "" {
				scopes = append(scopes, s)
			}
		}
	}
	displayName := out.Name
	if displayName == "" {
		displayName = out.Login
	}
	return &VerifyResult{DisplayName: displayName, Account: out.Login, Scopes: scopes}, nil
}

// verifyHTTPClient returns an http client with a tight timeout used only for
// the verification round-trip — separate from the tool HTTP client so
// verification cannot wedge a tool call.
func verifyHTTPClient() *http.Client {
	return &http.Client{Timeout: 10 * time.Second}
}
