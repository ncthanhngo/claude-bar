package domain

import (
	"encoding/json"
	"errors"
)

// CredentialBlob is the raw JSON string Claude Code stores in Keychain.
//
// Shape: {"claudeAiOauth": {"accessToken", "refreshToken", "expiresAt",
//                           "scopes", "subscriptionType"}}
type CredentialBlob string

// OAuthPayload is the inner claudeAiOauth object.
type OAuthPayload struct {
	AccessToken      string   `json:"accessToken"`
	RefreshToken     string   `json:"refreshToken"`
	ExpiresAt        int64    `json:"expiresAt"`
	Scopes           []string `json:"scopes,omitempty"`
	SubscriptionType string   `json:"subscriptionType,omitempty"`
}

// Extract parses the credential blob and returns the inner OAuth payload.
func (c CredentialBlob) Extract() (*OAuthPayload, error) {
	if c == "" {
		return nil, errors.New("empty credential blob")
	}
	var wrap struct {
		ClaudeAiOauth *OAuthPayload `json:"claudeAiOauth"`
	}
	if err := json.Unmarshal([]byte(c), &wrap); err != nil {
		return nil, err
	}
	if wrap.ClaudeAiOauth == nil {
		return nil, errors.New("missing claudeAiOauth field")
	}
	return wrap.ClaudeAiOauth, nil
}

// WithRefreshed returns a new blob with only the token fields updated.
// Fields not returned by the refresh endpoint (e.g. subscriptionType, accountUuid)
// are preserved from the existing blob so no metadata is silently dropped.
func (c CredentialBlob) WithRefreshed(p *OAuthPayload) (CredentialBlob, error) {
	var wrap map[string]any
	if err := json.Unmarshal([]byte(c), &wrap); err != nil {
		return "", err
	}
	existing, _ := wrap["claudeAiOauth"].(map[string]any)
	if existing == nil {
		existing = map[string]any{}
	}
	existing["accessToken"] = p.AccessToken
	existing["refreshToken"] = p.RefreshToken
	existing["expiresAt"] = p.ExpiresAt
	if len(p.Scopes) > 0 {
		existing["scopes"] = p.Scopes
	}
	wrap["claudeAiOauth"] = existing
	out, err := json.Marshal(wrap)
	if err != nil {
		return "", err
	}
	return CredentialBlob(out), nil
}

// ClaudeConfig mirrors the relevant subset of ~/.claude.json we care about.
type ClaudeConfig struct {
	OAuthAccount *OAuthAccount  `json:"oauthAccount,omitempty"`
	Raw          map[string]any `json:"-"`
}

// OAuthAccount is the identity portion stored in ~/.claude.json.
type OAuthAccount struct {
	EmailAddress     string `json:"emailAddress"`
	OrganizationName string `json:"organizationName,omitempty"`
	OrganizationUUID string `json:"organizationUuid,omitempty"`
	AccountUUID      string `json:"accountUuid,omitempty"`
}
