package usecase

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// IngestOAuthInput is the payload produced by the Swift WebView re-login flow
// after it exchanges an authorization_code for a Claude Code token pair. The
// shape mirrors the inner claudeAiOauth object so the caller can pass through
// whatever the OAuth provider returned without translating field names.
type IngestOAuthInput struct {
	AccountNum       int      `json:"accountNum"`
	AccessToken      string   `json:"accessToken"`
	RefreshToken     string   `json:"refreshToken"`
	ExpiresAt        int64    `json:"expiresAt"`
	Scopes           []string `json:"scopes,omitempty"`
	SubscriptionType string   `json:"subscriptionType,omitempty"`
	// ExpectedEmail is the email the Swift side decoded from the access_token
	// JWT (or read from a UserInfo lookup). When non-empty the usecase refuses
	// to overwrite an account whose registered email differs — protects against
	// the user authorising with the wrong Google account during the WebView
	// consent step and silently replacing another account's tokens.
	ExpectedEmail string `json:"expectedEmail,omitempty"`
}

// IngestOAuthResult tells the caller whether the live slot was also rewritten
// (true only when the target account is currently active).
type IngestOAuthResult struct {
	Account     *domain.Account `json:"account"`
	WroteLive   bool            `json:"wroteLive"`
	WroteBackup bool            `json:"wroteBackup"`
}

// IngestOAuthPayload writes a freshly-exchanged OAuth payload into an existing
// account's backup slot (and the live slot if that account is currently
// active). Designed for the in-app WebView re-login flow — does NOT touch
// ~/.claude.json's oauthAccount since the email/orgUuid are bound to the
// existing registry entry, not to whatever the user just authorised as.
//
// Caller is responsible for verifying the token's identity matches the
// account; ExpectedEmail acts as a backstop check.
func (s *Service) IngestOAuthPayload(ctx context.Context, in IngestOAuthInput) (*IngestOAuthResult, error) {
	if in.AccessToken == "" || in.RefreshToken == "" {
		return nil, errors.New("ingest oauth: access_token and refresh_token both required")
	}
	if in.ExpiresAt == 0 {
		return nil, errors.New("ingest oauth: expiresAt is required")
	}

	if err := s.Lock.Acquire(ctx); err != nil {
		return nil, err
	}
	defer s.Lock.Release()

	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return nil, err
	}
	acc, ok := reg.Accounts[in.AccountNum]
	if !ok || acc == nil {
		return nil, fmt.Errorf("account %d not found", in.AccountNum)
	}

	if in.ExpectedEmail != "" && !strings.EqualFold(strings.TrimSpace(in.ExpectedEmail), acc.Email) {
		return nil, fmt.Errorf(
			"identity mismatch: account %d is %s but the signed-in identity is %s — cancel and try again with the right Anthropic account",
			acc.Number, acc.Email, in.ExpectedEmail,
		)
	}

	blob, err := buildCredentialBlobFromInput(ctx, s, acc, in)
	if err != nil {
		return nil, err
	}

	if err := s.Backup.Write(ctx, acc.Number, acc.Email, blob); err != nil {
		return nil, fmt.Errorf("write backup credential: %w", err)
	}

	wroteLive := false
	if reg.ActiveAccountNumber == acc.Number {
		if err := s.Live.Write(ctx, blob); err != nil {
			return nil, fmt.Errorf("write live credential: %w", err)
		}
		wroteLive = true
	}

	return &IngestOAuthResult{Account: acc, WroteLive: wroteLive, WroteBackup: true}, nil
}

// buildCredentialBlobFromInput merges the fresh token fields into whatever
// metadata (subscriptionType, accountUuid…) the existing backup already had,
// so unrelated fields claude /login originally stored aren't silently lost on
// re-login. Falls back to a minimal blob when no backup exists yet.
func buildCredentialBlobFromInput(ctx context.Context, s *Service, acc *domain.Account, in IngestOAuthInput) (domain.CredentialBlob, error) {
	payload := &domain.OAuthPayload{
		AccessToken:      in.AccessToken,
		RefreshToken:     in.RefreshToken,
		ExpiresAt:        in.ExpiresAt,
		Scopes:           in.Scopes,
		SubscriptionType: in.SubscriptionType,
	}

	existing, err := s.Backup.Read(ctx, acc.Number, acc.Email)
	if err == nil && existing != "" {
		merged, err := existing.WithRefreshed(payload)
		if err == nil && merged != "" {
			if in.SubscriptionType != "" {
				return overwriteSubscriptionType(merged, in.SubscriptionType)
			}
			return merged, nil
		}
	}

	wrap := map[string]any{"claudeAiOauth": map[string]any{
		"accessToken":  payload.AccessToken,
		"refreshToken": payload.RefreshToken,
		"expiresAt":    payload.ExpiresAt,
	}}
	inner := wrap["claudeAiOauth"].(map[string]any)
	if len(payload.Scopes) > 0 {
		inner["scopes"] = payload.Scopes
	}
	if payload.SubscriptionType != "" {
		inner["subscriptionType"] = payload.SubscriptionType
	}
	raw, err := json.Marshal(wrap)
	if err != nil {
		return "", err
	}
	return domain.CredentialBlob(raw), nil
}

// overwriteSubscriptionType ensures a caller-supplied subscriptionType wins
// over a stale value carried forward from the merged backup blob.
func overwriteSubscriptionType(blob domain.CredentialBlob, sub string) (domain.CredentialBlob, error) {
	var wrap map[string]any
	if err := json.Unmarshal([]byte(blob), &wrap); err != nil {
		return blob, nil
	}
	inner, _ := wrap["claudeAiOauth"].(map[string]any)
	if inner == nil {
		return blob, nil
	}
	inner["subscriptionType"] = sub
	wrap["claudeAiOauth"] = inner
	out, err := json.Marshal(wrap)
	if err != nil {
		return "", err
	}
	return domain.CredentialBlob(out), nil
}
