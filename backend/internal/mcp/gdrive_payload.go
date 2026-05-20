package mcp

import (
	"encoding/json"
	"time"
)

// GDrivePayload is the JSON Claude Bar stores in Keychain for the Google
// Drive connector. It contains the OAuth client ID used for refresh (no
// client secret — we use PKCE flow), the refresh token, and a cached
// access token to avoid refreshing on every call.
type GDrivePayload struct {
	ClientID         string    `json:"clientId"`
	RefreshToken     string    `json:"refreshToken"`
	AccessToken      string    `json:"accessToken,omitempty"`
	AccessExpiresAt  time.Time `json:"accessExpiresAt,omitempty"`
	Scope            string    `json:"scope,omitempty"`
}

// Marshal returns the JSON encoding for Keychain storage.
func (p *GDrivePayload) Marshal() (string, error) {
	b, err := json.Marshal(p)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// UnmarshalGDrivePayload parses Keychain-stored JSON.
func UnmarshalGDrivePayload(s string) (*GDrivePayload, error) {
	var p GDrivePayload
	if err := json.Unmarshal([]byte(s), &p); err != nil {
		return nil, err
	}
	return &p, nil
}
