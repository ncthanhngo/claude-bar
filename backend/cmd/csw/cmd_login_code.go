package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/oauth"
	"github.com/soi/claude-swap-widget/backend/internal/usecase"
)

// runLoginURL starts a browser sign-in for a new account (Windows tray). The
// caller opens url, then hands the pasted code plus state/verifier back to
// add-oauth-code.
func runLoginURL(args []string) error {
	fs := flag.NewFlagSet("login-url", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	a, err := oauth.NewLoginAttempt()
	if err != nil {
		return err
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(a)
	}
	fmt.Println(a.URL)
	return nil
}

// addOAuthCodeInput is the stdin payload of add-oauth-code.
type addOAuthCodeInput struct {
	Code     string `json:"code"` // as pasted: "code#state" or a bare code
	State    string `json:"state"`
	Verifier string `json:"verifier"`
	Nickname string `json:"nickname,omitempty"`
	// ExpectedEmail, when set, is a re-login of that account: a sign-in
	// with any other account is refused instead of saved.
	ExpectedEmail string `json:"expectedEmail,omitempty"`
}

// runAddOAuthCode exchanges a pasted sign-in code and saves the account
// (backup only, like add-oauth). Tokens stay inside csw: the code arrives on
// stdin and only account metadata is printed.
func runAddOAuthCode(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("add-oauth-code", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		return fmt.Errorf("read stdin: %w", err)
	}
	var in addOAuthCodeInput
	if err := json.Unmarshal(raw, &in); err != nil {
		return fmt.Errorf("decode stdin payload: %w", err)
	}
	if in.State == "" || in.Verifier == "" {
		return fmt.Errorf("add-oauth-code: state and verifier are required")
	}
	code, err := oauth.SplitPastedCode(in.Code, in.State)
	if err != nil {
		return err
	}
	tok, err := oauth.ExchangeCode(ctx, code, in.State, in.Verifier)
	if err != nil {
		return err
	}
	if in.ExpectedEmail != "" && !strings.EqualFold(strings.TrimSpace(tok.Email), strings.TrimSpace(in.ExpectedEmail)) {
		return fmt.Errorf("signed in as %s, not %s — nothing was saved", tok.Email, in.ExpectedEmail)
	}
	res, err := svc.AddAccountFromOAuth(ctx, usecase.AddAccountFromOAuthInput{
		AccessToken:      tok.AccessToken,
		RefreshToken:     tok.RefreshToken,
		ExpiresAt:        tok.ExpiresAt,
		Scopes:           tok.Scopes,
		Email:            tok.Email,
		OrgUUID:          tok.OrgUUID,
		OrganizationName: tok.OrganizationName,
		Nickname:         in.Nickname,
	})
	if err != nil {
		return err
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(res)
	}
	if res.WasDuplicate {
		fmt.Printf("Account %s was already saved as Account-%d; its saved login was updated.\n",
			res.Account.Email, res.DuplicateOfNum)
	} else {
		fmt.Printf("Added Account-%d (%s).\n", res.Account.Number, res.Account.DisplayName())
	}
	return nil
}
