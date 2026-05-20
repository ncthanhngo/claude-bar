package mcp

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestVerifySlackToken_OK(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer xoxp-good" {
			t.Errorf("missing/bad Bearer: %q", r.Header.Get("Authorization"))
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true,"team":"Acme","user":"alice","team_id":"T1","user_id":"U1"}`))
	}))
	defer srv.Close()

	res, err := verifySlackAt(context.Background(), srv.Client(), srv.URL, "xoxp-good")
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if res.DisplayName != "Acme" || res.Account != "alice" {
		t.Errorf("unexpected: %+v", res)
	}
}

func TestVerifySlackToken_BadAuth(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":false,"error":"invalid_auth"}`))
	}))
	defer srv.Close()

	_, err := verifySlackAt(context.Background(), srv.Client(), srv.URL, "xoxp-bad")
	if err == nil || !strings.Contains(err.Error(), "invalid_auth") {
		t.Fatalf("expected invalid_auth, got %v", err)
	}
}

func TestVerifyClickUpToken_OK(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "pk_1_AAA" {
			t.Errorf("ClickUp must send raw token, got %q", r.Header.Get("Authorization"))
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"user":{"id":42,"email":"a@b.c","username":"Alice"}}`))
	}))
	defer srv.Close()

	res, err := verifyClickUpAt(context.Background(), srv.Client(), srv.URL, "pk_1_AAA")
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if res.DisplayName != "Alice" || res.Account != "a@b.c" {
		t.Errorf("unexpected: %+v", res)
	}
}

func TestVerifyClickUpToken_Unauthorized(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"err":"Oauth token not found"}`, http.StatusUnauthorized)
	}))
	defer srv.Close()

	_, err := verifyClickUpAt(context.Background(), srv.Client(), srv.URL, "pk_bad")
	if err == nil || !strings.Contains(err.Error(), "unauthorized") {
		t.Fatalf("expected unauthorized, got %v", err)
	}
}

func TestVerifyGDriveAccess_OK(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
			t.Errorf("expected Bearer Authorization, got %q", r.Header.Get("Authorization"))
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"user":{"emailAddress":"u@g.c","displayName":"User"}}`))
	}))
	defer srv.Close()

	res, err := verifyGDriveAt(context.Background(), srv.Client(), srv.URL, "ya29.token")
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if res.Account != "u@g.c" || res.DisplayName != "User" {
		t.Errorf("unexpected: %+v", res)
	}
}
