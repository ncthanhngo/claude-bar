// Package cswclient runs the bundled csw.exe and decodes its JSON. The tray
// never touches credentials itself.
package cswclient

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// Account mirrors csw's account JSON.
type Account struct {
	Number           int    `json:"number"`
	Email            string `json:"email"`
	Nickname         string `json:"nickname,omitempty"`
	OrganizationName string `json:"organizationName,omitempty"`
	OrganizationUUID string `json:"organizationUuid,omitempty"`
}

// DisplayName is the nickname, else the email.
func (a Account) DisplayName() string {
	if a.Nickname != "" {
		return a.Nickname
	}
	return a.Email
}

// AccountView is one row of `csw list`.
type AccountView struct {
	Account          Account `json:"account"`
	IsActive         bool    `json:"isActive"`
	CredentialState  string  `json:"credentialState,omitempty"`
	CredentialError  string  `json:"credentialError,omitempty"`
	SubscriptionType string  `json:"subscriptionType,omitempty"`
	Usage            *Usage  `json:"usage,omitempty"`
}

// Usage is an account's rate-limit windows (only from ListWithUsage).
type Usage struct {
	FiveHour       *UsageWindow `json:"fiveHour,omitempty"`
	SevenDay       *UsageWindow `json:"sevenDay,omitempty"`
	SevenDayScoped *UsageWindow `json:"sevenDayScoped,omitempty"`
	ScopedLabel    string       `json:"scopedLabel,omitempty"`
}

// UsageWindow is one window: percent used and when it resets.
type UsageWindow struct {
	UtilizationPct float64 `json:"utilizationPct"`
	ResetsAt       string  `json:"resetsAt,omitempty"`
}

// ListResult is `csw list --json`.
type ListResult struct {
	Accounts            []AccountView `json:"accounts"`
	ActiveAccountNumber int           `json:"activeAccountNumber"`
}

// AddResult is `csw add --json`.
type AddResult struct {
	Account        Account `json:"account"`
	WasDuplicate   bool    `json:"wasDuplicate"`
	DuplicateOfNum int     `json:"duplicateOfNum,omitempty"`
}

// Runner executes csw with args (and stdin, when non-nil) and returns
// stdout; a failed run returns stderr's last line as the error.
type Runner func(ctx context.Context, stdin []byte, args ...string) ([]byte, error)

// Client talks to csw.
type Client struct{ run Runner }

// New runs the csw binary at path.
func New(path string) *Client {
	return &Client{run: func(ctx context.Context, stdin []byte, args ...string) ([]byte, error) {
		cmd := exec.CommandContext(ctx, path, args...)
		hideConsole(cmd)
		if stdin != nil {
			cmd.Stdin = bytes.NewReader(stdin)
		}
		var stdout, stderr bytes.Buffer
		cmd.Stdout, cmd.Stderr = &stdout, &stderr
		if err := cmd.Run(); err != nil {
			return nil, cswError(stderr.String(), err)
		}
		return stdout.Bytes(), nil
	}}
}

// NewWithRunner is for tests.
func NewWithRunner(r Runner) *Client { return &Client{run: r} }

func cswError(stderr string, err error) error {
	lines := strings.Split(strings.TrimSpace(stderr), "\n")
	if msg := strings.TrimSpace(lines[len(lines)-1]); msg != "" {
		return errors.New(strings.TrimPrefix(msg, "error: "))
	}
	return err
}

func (c *Client) runJSON(ctx context.Context, out any, args ...string) error {
	return c.runJSONIn(ctx, nil, out, args...)
}

func (c *Client) runJSONIn(ctx context.Context, stdin []byte, out any, args ...string) error {
	data, err := c.run(ctx, stdin, args...)
	if err != nil {
		return err
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(data, out); err != nil {
		return fmt.Errorf("csw %s: unexpected output: %w", args[0], err)
	}
	return nil
}

// List returns accounts without touching the network.
func (c *Client) List(ctx context.Context) (*ListResult, error) {
	var r ListResult
	return &r, c.runJSON(ctx, &r, "list", "--json", "--metadata-only")
}

// ListWithUsage also returns each account's usage. It calls Anthropic
// (csw caches and backs off), so the tray only uses it for the popover.
func (c *Client) ListWithUsage(ctx context.Context) (*ListResult, error) {
	var r ListResult
	return &r, c.runJSON(ctx, &r, "list", "--json")
}

// Switch makes account num the live Claude Code login.
func (c *Client) Switch(ctx context.Context, num int) error {
	return c.runJSON(ctx, nil, "switch", "--json", strconv.Itoa(num))
}

// AddCurrent saves the login Claude Code is using now as an account.
func (c *Client) AddCurrent(ctx context.Context, nickname string) (*AddResult, error) {
	var r AddResult
	args := []string{"add", "--json"}
	if nickname != "" {
		args = append(args, "--nickname", nickname)
	}
	return &r, c.runJSON(ctx, &r, args...)
}

// SignIn is one browser sign-in attempt from `csw login-url`. State and
// Verifier go back to AddSignedIn with the code.
type SignIn struct {
	URL      string `json:"url"`
	State    string `json:"state"`
	Verifier string `json:"verifier"`
}

// StartSignIn prepares a sign-in for a new account.
func (c *Client) StartSignIn(ctx context.Context) (*SignIn, error) {
	var s SignIn
	return &s, c.runJSON(ctx, &s, "login-url", "--json")
}

// AddSignedIn exchanges the code from a finished sign-in ("code#state" or a
// bare code) and saves the account. csw does the token exchange, so tokens
// never pass through the tray; the code travels on stdin, not argv. A
// non-empty expectedEmail makes it a re-login of that account: signing in
// with another account is refused.
func (c *Client) AddSignedIn(ctx context.Context, s *SignIn, code, nickname, expectedEmail string) (*AddResult, error) {
	in, err := json.Marshal(map[string]string{
		"code": code, "state": s.State, "verifier": s.Verifier, "nickname": nickname,
		"expectedEmail": expectedEmail,
	})
	if err != nil {
		return nil, err
	}
	var r AddResult
	return &r, c.runJSONIn(ctx, in, &r, "add-oauth-code", "--json")
}

// SnapshotActive copies Claude Code's live login into the active account's
// saved copy, so a refresh token Claude Code rotated is never lost. csw
// refuses when Claude Code is logged in to a different account.
func (c *Client) SnapshotActive(ctx context.Context) error {
	return c.runJSON(ctx, nil, "snapshot-active", "--json")
}

// Rename sets (or with "" clears) an account's nickname.
func (c *Client) Rename(ctx context.Context, num int, nickname string) error {
	return c.runJSON(ctx, nil, "rename", "--json", strconv.Itoa(num), nickname)
}

// Remove deletes an account and its backup.
func (c *Client) Remove(ctx context.Context, num int) error {
	return c.runJSON(ctx, nil, "remove", "--json", strconv.Itoa(num))
}

// NeedsLogin probes every account (token refresh + usage call where
// needed) and returns the inactive accounts whose saved login is gone or
// was rejected. Network errors and rate limits don't count: right after
// sign-in the network is often not up yet.
func (c *Client) NeedsLogin(ctx context.Context) (map[int]bool, error) {
	var r struct {
		Results []struct {
			AccountNum int  `json:"accountNum"`
			IsActive   bool `json:"isActive"`
			Checks     []struct {
				Name    string `json:"name"`
				Passed  bool   `json:"passed"`
				Skipped bool   `json:"skipped"`
				Detail  string `json:"detail"`
			} `json:"checks"`
		} `json:"results"`
	}
	if err := c.runJSON(ctx, &r, "verify", "--json"); err != nil {
		return nil, err
	}
	dead := map[int]bool{}
	for _, v := range r.Results {
		if v.IsActive {
			continue
		}
		for _, ch := range v.Checks {
			if ch.Passed || ch.Skipped {
				continue
			}
			missing := ch.Name == "credentials_present" || ch.Name == "credentials_valid"
			rejected := strings.Contains(ch.Detail, "invalid_grant") || strings.Contains(ch.Detail, "401")
			if missing || rejected {
				dead[v.AccountNum] = true
			}
		}
	}
	return dead, nil
}
