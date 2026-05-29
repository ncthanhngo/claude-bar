package usecase

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// AddAccountFromOAuthInput is a WebView-exchanged OAuth payload for a NEW
// account (the user signed into Claude in an embedded WebView rather than via
// `claude /login`). Identity is supplied explicitly because the access token
// is opaque (not a JWT): email + orgUuid come from the token-exchange response
// `account`/`organization` objects.
//
// OrgUUID is REQUIRED. A single email can belong to multiple Anthropic orgs,
// so email-only dedupe would collapse or overwrite the wrong org's slot. If the
// exchange response omits the org, the caller must abort rather than guess.
type AddAccountFromOAuthInput struct {
	AccessToken      string   `json:"accessToken"`
	RefreshToken     string   `json:"refreshToken"`
	ExpiresAt        int64    `json:"expiresAt"`
	Scopes           []string `json:"scopes,omitempty"`
	SubscriptionType string   `json:"subscriptionType,omitempty"`
	Email            string   `json:"email"`
	OrgUUID          string   `json:"orgUuid"`
	OrganizationName string   `json:"organizationName,omitempty"`
	Nickname         string   `json:"nickname,omitempty"`
}

// AddAccountFromOAuth creates a new account from a WebView OAuth sign-in, or
// refreshes the backup of an existing account when the signed-in identity
// already exists.
//
// Safe by construction (this is why add-account does not need the re-login
// identity guard): it never targets a caller-supplied slot. It resolves the
// slot ONLY by deduping (email, orgUuid) from the authoritative exchange
// response, then writes the BACKUP of the matched-or-new account. It never
// writes the live credential or patches ~/.claude.json, so adding an account
// can never overwrite the running CLI's session or another account's slot.
func (s *Service) AddAccountFromOAuth(ctx context.Context, in AddAccountFromOAuthInput) (*AddAccountResult, error) {
	if in.AccessToken == "" || in.RefreshToken == "" {
		return nil, errors.New("add account: access_token and refresh_token both required")
	}
	if in.ExpiresAt == 0 {
		return nil, errors.New("add account: expiresAt is required")
	}
	email := strings.TrimSpace(in.Email)
	if email == "" {
		return nil, errors.New("add account: email is required (from the token-exchange response)")
	}
	orgUUID := strings.TrimSpace(in.OrgUUID)
	if orgUUID == "" {
		return nil, errors.New(
			"add account: organization uuid missing — cannot safely dedupe by identity; aborting rather than risk overwriting another org's account")
	}

	if err := s.Lock.Acquire(ctx); err != nil {
		return nil, err
	}
	defer s.Lock.Release()

	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return nil, err
	}

	dupNum := reg.FindByIdentity(email, orgUUID)
	var acct *domain.Account
	if dupNum != 0 {
		acct = reg.Accounts[dupNum]
		if in.Nickname != "" {
			acct.Nickname = in.Nickname
		}
	} else {
		num := reg.NextAccountNumber()
		acct = &domain.Account{
			Number:           num,
			Email:            email,
			OrganizationName: in.OrganizationName,
			OrganizationUUID: orgUUID,
			Nickname:         in.Nickname,
			CreatedAt:        time.Now().UTC(),
		}
		reg.Accounts[num] = acct
		reg.Sequence = append(reg.Sequence, num)
	}

	// Reuse the re-login blob builder: merges the fresh tokens over any
	// existing backup (identity match) or emits a minimal blob (new account).
	blob, err := buildCredentialBlobFromInput(ctx, s, acct, IngestOAuthInput{
		AccessToken:      in.AccessToken,
		RefreshToken:     in.RefreshToken,
		ExpiresAt:        in.ExpiresAt,
		Scopes:           in.Scopes,
		SubscriptionType: in.SubscriptionType,
	})
	if err != nil {
		return nil, err
	}
	if err := s.Backup.Write(ctx, acct.Number, acct.Email, blob); err != nil {
		return nil, fmt.Errorf("write backup credential: %w", err)
	}
	if err := s.Registry.Save(ctx, reg); err != nil {
		return nil, err
	}

	return &AddAccountResult{
		Account:        acct,
		WasDuplicate:   dupNum != 0,
		DuplicateOfNum: dupNum,
	}, nil
}
