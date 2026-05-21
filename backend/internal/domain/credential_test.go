package domain

import (
	"encoding/json"
	"testing"
)

func TestWithRefreshedPreservesMetadataFields(t *testing.T) {
	original := CredentialBlob(`{"claudeAiOauth":{"accessToken":"old","refreshToken":"old-r","expiresAt":100,"subscriptionType":"claude_max","accountUuid":"abc-123"}}`)

	fresh := &OAuthPayload{
		AccessToken:  "new-token",
		RefreshToken: "new-refresh",
		ExpiresAt:    9999,
	}

	updated, err := original.WithRefreshed(fresh)
	if err != nil {
		t.Fatalf("WithRefreshed: %v", err)
	}

	payload, err := updated.Extract()
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}

	if payload.AccessToken != "new-token" {
		t.Errorf("accessToken = %q, want new-token", payload.AccessToken)
	}
	if payload.RefreshToken != "new-refresh" {
		t.Errorf("refreshToken = %q, want new-refresh", payload.RefreshToken)
	}
	if payload.ExpiresAt != 9999 {
		t.Errorf("expiresAt = %d, want 9999", payload.ExpiresAt)
	}
	if payload.SubscriptionType != "claude_max" {
		t.Errorf("subscriptionType = %q, want claude_max (preserved)", payload.SubscriptionType)
	}

	// Verify accountUuid is preserved in raw JSON (not in OAuthPayload struct but present in blob)
	var raw map[string]any
	_ = json.Unmarshal([]byte(updated), &raw)
	oauth, _ := raw["claudeAiOauth"].(map[string]any)
	if oauth["accountUuid"] != "abc-123" {
		t.Errorf("accountUuid = %v, want abc-123 (preserved)", oauth["accountUuid"])
	}
}

func TestWithRefreshedPreservesExistingScopesWhenRefreshHasNone(t *testing.T) {
	original := CredentialBlob(`{"claudeAiOauth":{"accessToken":"old","refreshToken":"old-r","expiresAt":100,"scopes":["user:read","org:read"],"subscriptionType":"pro"}}`)

	fresh := &OAuthPayload{
		AccessToken:  "new",
		RefreshToken: "new-r",
		ExpiresAt:    9999,
		Scopes:       nil, // refresh endpoint did not return scopes
	}

	updated, err := original.WithRefreshed(fresh)
	if err != nil {
		t.Fatalf("WithRefreshed: %v", err)
	}

	payload, err := updated.Extract()
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}

	if len(payload.Scopes) != 2 || payload.Scopes[0] != "user:read" {
		t.Errorf("scopes = %v, want [user:read org:read] (preserved when refresh returns none)", payload.Scopes)
	}
	if payload.SubscriptionType != "pro" {
		t.Errorf("subscriptionType = %q, want pro (preserved)", payload.SubscriptionType)
	}
}

func TestWithRefreshedUpdatesScopesWhenRefreshReturnsNew(t *testing.T) {
	original := CredentialBlob(`{"claudeAiOauth":{"accessToken":"old","refreshToken":"old-r","expiresAt":100,"scopes":["user:read"]}}`)

	fresh := &OAuthPayload{
		AccessToken:  "new",
		RefreshToken: "new-r",
		ExpiresAt:    9999,
		Scopes:       []string{"user:read", "org:write"},
	}

	updated, err := original.WithRefreshed(fresh)
	if err != nil {
		t.Fatalf("WithRefreshed: %v", err)
	}

	payload, err := updated.Extract()
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}

	if len(payload.Scopes) != 2 || payload.Scopes[1] != "org:write" {
		t.Errorf("scopes = %v, want [user:read org:write] (updated from refresh response)", payload.Scopes)
	}
}

func TestWithRefreshedPreservesOuterBlobFields(t *testing.T) {
	original := CredentialBlob(`{"claudeAiOauth":{"accessToken":"old","refreshToken":"old-r","expiresAt":0},"otherTopLevel":"preserved"}`)

	fresh := &OAuthPayload{AccessToken: "new", RefreshToken: "new-r", ExpiresAt: 1}

	updated, err := original.WithRefreshed(fresh)
	if err != nil {
		t.Fatalf("WithRefreshed: %v", err)
	}

	var raw map[string]any
	if err := json.Unmarshal([]byte(updated), &raw); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if raw["otherTopLevel"] != "preserved" {
		t.Errorf("otherTopLevel = %v, want preserved", raw["otherTopLevel"])
	}
}
