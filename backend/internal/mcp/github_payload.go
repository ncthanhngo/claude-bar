package mcp

import (
	"encoding/json"
	"time"
)

// GitHubPayload is the JSON Claude Bar stores in Keychain for the GitHub
// connector. OAuth App tokens use `gho_` user-to-server credentials; the
// refresh token is optional because legacy OAuth App grants do not rotate.
type GitHubPayload struct {
	ClientID         string    `json:"clientId"`
	ClientSecret     string    `json:"clientSecret,omitempty"`
	AccessToken      string    `json:"accessToken"`
	AccessExpiresAt  time.Time `json:"accessExpiresAt,omitempty"`
	RefreshToken     string    `json:"refreshToken,omitempty"`
	RefreshExpiresAt time.Time `json:"refreshExpiresAt,omitempty"`
	Scope            string    `json:"scope,omitempty"`
	Login            string    `json:"login,omitempty"`
}

// Marshal returns the JSON encoding for Keychain storage.
func (p *GitHubPayload) Marshal() (string, error) {
	b, err := json.Marshal(p)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// UnmarshalGitHubPayload parses Keychain-stored JSON.
func UnmarshalGitHubPayload(s string) (*GitHubPayload, error) {
	var p GitHubPayload
	if err := json.Unmarshal([]byte(s), &p); err != nil {
		return nil, err
	}
	return &p, nil
}
