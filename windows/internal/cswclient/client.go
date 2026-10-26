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
	Account         Account `json:"account"`
	IsActive        bool    `json:"isActive"`
	CredentialState string  `json:"credentialState,omitempty"`
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

// Runner executes csw with args and returns stdout; a failed run returns
// stderr's last line as the error.
type Runner func(ctx context.Context, args ...string) ([]byte, error)

// Client talks to csw.
type Client struct{ run Runner }

// New runs the csw binary at path.
func New(path string) *Client {
	return &Client{run: func(ctx context.Context, args ...string) ([]byte, error) {
		cmd := exec.CommandContext(ctx, path, args...)
		hideConsole(cmd)
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
	data, err := c.run(ctx, args...)
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
