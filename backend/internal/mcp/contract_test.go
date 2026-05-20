//go:build contract

// Package mcp contract tests run against real providers. They are gated
// behind the "contract" build tag AND require staging credentials via env:
//
//   SLACK_TEST_TOKEN=xoxp-…
//   CLICKUP_TEST_TOKEN=pk_…
//   GDRIVE_TEST_ACCESS_TOKEN=ya29.…   (use after a manual OAuth dance)
//
// Run with:
//   go test -tags=contract -run TestContract ./internal/mcp/...
//
// Missing env vars cause the corresponding test to skip — never fail —
// so this file can sit in the repo without breaking default CI.
package mcp

import (
	"context"
	"net/http"
	"os"
	"testing"
	"time"
)

func contractClient() *http.Client {
	return &http.Client{Timeout: 15 * time.Second}
}

func TestContract_VerifySlackToken(t *testing.T) {
	tok := os.Getenv("SLACK_TEST_TOKEN")
	if tok == "" {
		t.Skip("SLACK_TEST_TOKEN not set")
	}
	res, err := VerifySlackToken(context.Background(), contractClient(), tok)
	if err != nil {
		t.Fatalf("real Slack auth.test failed: %v", err)
	}
	if res.DisplayName == "" || res.Account == "" {
		t.Errorf("expected team + user, got %+v", res)
	}
}

func TestContract_VerifyClickUpToken(t *testing.T) {
	tok := os.Getenv("CLICKUP_TEST_TOKEN")
	if tok == "" {
		t.Skip("CLICKUP_TEST_TOKEN not set")
	}
	res, err := VerifyClickUpToken(context.Background(), contractClient(), tok)
	if err != nil {
		t.Fatalf("real ClickUp /user failed: %v", err)
	}
	if res.Account == "" {
		t.Errorf("expected user email, got %+v", res)
	}
}

func TestContract_VerifyGDriveAccess(t *testing.T) {
	tok := os.Getenv("GDRIVE_TEST_ACCESS_TOKEN")
	if tok == "" {
		t.Skip("GDRIVE_TEST_ACCESS_TOKEN not set")
	}
	res, err := VerifyGDriveAccess(context.Background(), contractClient(), tok)
	if err != nil {
		t.Fatalf("real Drive /about failed: %v", err)
	}
	if res.Account == "" {
		t.Errorf("expected user email, got %+v", res)
	}
}
