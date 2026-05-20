package mcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// TestGDriveRefreshUsesCachedAccessToken proves the cached access token is
// returned without an HTTP round-trip when it is still valid.
func TestGDriveRefreshUsesCachedAccessToken(t *testing.T) {
	var hits int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"ya29.fresh","expires_in":3600,"token_type":"Bearer"}`))
	}))
	defer srv.Close()

	payload := &GDrivePayload{
		ClientID:        "client.apps.googleusercontent.com",
		RefreshToken:    "1//refresh",
		AccessToken:     "ya29.cached",
		AccessExpiresAt: time.Now().Add(30 * time.Minute),
	}
	marshalled, _ := payload.Marshal()

	secrets := fakeSecrets{key(1, domain.MCPServiceGDrive): marshalled}
	cc := &CallContext{
		AccountNumber: 1,
		Service:       domain.MCPServiceGDrive,
		Payload:       marshalled,
	}
	gw := newTestGateway()
	gw.Resolver = &Resolver{Secrets: secrets}

	got, err := gw.gdriveRefresh(context.Background(), cc)
	if err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if got != "ya29.cached" {
		t.Errorf("want cached token, got %q", got)
	}
	if hits != 0 {
		t.Errorf("cached token should not hit refresh endpoint, hits=%d", hits)
	}
}

// TestGDriveRefreshExchangesExpiredToken proves the refresh endpoint is
// called when the cached access token has expired, and the new token is
// persisted back to the secret store.
func TestGDriveRefreshExchangesExpiredToken(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		// Verify the refresh form includes refresh_token + grant_type.
		if !strings.Contains(string(body), "refresh_token=1%2F%2Frefresh") {
			t.Errorf("missing refresh_token in form: %s", body)
		}
		if !strings.Contains(string(body), "grant_type=refresh_token") {
			t.Errorf("missing grant_type=refresh_token: %s", body)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"ya29.fresh","expires_in":3600,"token_type":"Bearer"}`))
	}))
	defer srv.Close()

	// Point package-level token URL at fake server.
	prev := tokenURLForTest
	tokenURLForTest = srv.URL
	defer func() { tokenURLForTest = prev }()

	payload := &GDrivePayload{
		ClientID:        "c.apps.googleusercontent.com",
		RefreshToken:    "1//refresh",
		AccessToken:     "ya29.expired",
		AccessExpiresAt: time.Now().Add(-1 * time.Hour),
	}
	marshalled, _ := payload.Marshal()
	secrets := fakeSecrets{key(1, domain.MCPServiceGDrive): marshalled}
	cc := &CallContext{
		AccountNumber: 1,
		Service:       domain.MCPServiceGDrive,
		Payload:       marshalled,
	}
	gw := newTestGateway()
	gw.Resolver = &Resolver{Secrets: secrets}

	got, err := gw.gdriveRefresh(context.Background(), cc)
	if err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if got != "ya29.fresh" {
		t.Errorf("want refreshed token, got %q", got)
	}

	// Persisted back?
	stored, _ := secrets.Read(context.Background(), 1, domain.MCPServiceGDrive)
	var back GDrivePayload
	_ = json.Unmarshal([]byte(stored), &back)
	if back.AccessToken != "ya29.fresh" {
		t.Errorf("refreshed token not persisted, got %q", back.AccessToken)
	}
	if back.AccessExpiresAt.Before(time.Now()) {
		t.Errorf("AccessExpiresAt should be in the future, got %v", back.AccessExpiresAt)
	}
}
