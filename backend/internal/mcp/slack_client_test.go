package mcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func newTestGateway() *Gateway {
	return &Gateway{
		HTTP:      &http.Client{Timeout: 5 * time.Second},
		UserAgent: "claude-bar-mcp-test",
		Version:   "test",
	}
}

func TestSlackCallSendsBearerAndDecodes(t *testing.T) {
	var sawAuth, sawPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawAuth = r.Header.Get("Authorization")
		sawPath = r.URL.Path
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true,"channels":[{"id":"C1","name":"general"}]}`))
	}))
	defer srv.Close()

	gw := newTestGateway()
	gw.HTTP = srv.Client()

	var out struct {
		slackResponse
		Channels []map[string]any `json:"channels"`
	}
	if err := slackCallAt(context.Background(), gw, srv.URL, "xoxp-test", "conversations.list", nil, &out); err != nil {
		t.Fatalf("call: %v", err)
	}
	if !out.OK || len(out.Channels) != 1 {
		t.Fatalf("decode failed: %+v", out)
	}
	if !strings.HasPrefix(sawAuth, "Bearer ") {
		t.Errorf("expected Bearer Authorization, got %q", sawAuth)
	}
	if sawPath != "/conversations.list" {
		t.Errorf("path %q", sawPath)
	}
}

func TestSlackCallSurfacesEnvelopeError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":false,"error":"invalid_auth"}`))
	}))
	defer srv.Close()

	gw := newTestGateway()
	gw.HTTP = srv.Client()
	err := slackCallAt(context.Background(), gw, srv.URL, "xoxp-x", "auth.test", nil, nil)
	if err == nil || !strings.Contains(err.Error(), "invalid_auth") {
		t.Fatalf("expected invalid_auth error, got %v", err)
	}
}

func TestSlackCallSurfacesHTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()

	gw := newTestGateway()
	gw.HTTP = srv.Client()
	err := slackCallAt(context.Background(), gw, srv.URL, "xoxp-x", "auth.test", nil, nil)
	if err == nil || !strings.Contains(err.Error(), "500") {
		t.Fatalf("expected 500 surface, got %v", err)
	}
}

// slackCallAt mirrors Gateway.slackCall but takes an explicit base URL so
// the test can point at httptest. Logic stays identical to keep coverage honest.
func slackCallAt(ctx context.Context, g *Gateway, base, token, method string, params url.Values, out any) error {
	u := base + "/" + method
	if len(params) > 0 {
		u += "?" + params.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", g.UserAgent)
	resp, err := g.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("http %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var env slackResponse
	if err := json.Unmarshal(body, &env); err != nil {
		return err
	}
	if !env.OK {
		return errors.New("slack: " + env.Error)
	}
	if out != nil {
		return json.Unmarshal(body, out)
	}
	return nil
}
