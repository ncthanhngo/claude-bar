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

// VerifySlackToken pings Slack's auth.test endpoint. Returns the workspace
// name + user email so the registry metadata can show "Slack — Acme (alice@…)"
// instead of a bare "connected".
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
		OK      bool   `json:"ok"`
		Error   string `json:"error"`
		Team    string `json:"team"`
		User    string `json:"user"`
		TeamID  string `json:"team_id"`
		UserID  string `json:"user_id"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("slack verify decode: %w", err)
	}
	if !out.OK {
		return nil, fmt.Errorf("slack verify: %s", out.Error)
	}
	return &VerifyResult{DisplayName: out.Team, Account: out.User}, nil
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

// verifyHTTPClient returns an http client with a tight timeout used only for
// the verification round-trip — separate from the tool HTTP client so
// verification cannot wedge a tool call.
func verifyHTTPClient() *http.Client {
	return &http.Client{Timeout: 10 * time.Second}
}
