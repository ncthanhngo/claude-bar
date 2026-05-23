package mcp

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	mcpgo "github.com/mark3labs/mcp-go/mcp"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

func newGitHubTestGateway(client *http.Client) *Gateway {
	gw := newTestGateway()
	gw.HTTP = client
	reg := domain.NewRegistry()
	reg.ActiveAccountNumber = 1
	reg.Sequence = []int{1}
	reg.Accounts[1] = &domain.Account{
		Number: 1,
		Email:  "github@example.com",
		MCPConnectors: domain.AccountConnectors{
			domain.MCPServiceGitHub: &domain.MCPConnector{Enabled: true},
		},
	}
	payload := &GitHubPayload{
		ClientID:        "cid",
		ClientSecret:    "csecret",
		AccessToken:     "gho_unit-test-token",
		AccessExpiresAt: time.Now().Add(time.Hour),
	}
	raw, _ := payload.Marshal()
	gw.Resolver = &Resolver{
		Registry: &fakeRegistry{reg: reg},
		Secrets:  fakeSecrets{key(1, domain.MCPServiceGitHub): raw},
	}
	return gw
}

func TestGitHubListPRsSendsBearerAndPath(t *testing.T) {
	var gotAuth, gotPath, gotQuery, gotAccept, gotAPIVer string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotPath = r.URL.Path
		gotQuery = r.URL.RawQuery
		gotAccept = r.Header.Get("Accept")
		gotAPIVer = r.Header.Get("X-GitHub-Api-Version")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`[{"number":42,"title":"hi"}]`))
	}))
	defer srv.Close()

	oldBase := githubAPIBaseForTest
	githubAPIBaseForTest = srv.URL
	defer func() { githubAPIBaseForTest = oldBase }()

	gw := newGitHubTestGateway(srv.Client())
	res, err := gw.githubListPRs(context.Background(), newCallRequest(map[string]any{
		"owner": "octocat", "repo": "hello-world", "state": "open", "per_page": 50,
	}))
	if err != nil {
		t.Fatalf("call: %v", err)
	}
	if res == nil || res.IsError {
		t.Fatalf("unexpected result: %+v", res)
	}
	if gotAuth != "Bearer gho_unit-test-token" {
		t.Errorf("Authorization = %q, want Bearer ...", gotAuth)
	}
	if gotPath != "/repos/octocat/hello-world/pulls" {
		t.Errorf("path = %q", gotPath)
	}
	if !strings.Contains(gotQuery, "state=open") || !strings.Contains(gotQuery, "per_page=50") {
		t.Errorf("query = %q", gotQuery)
	}
	if gotAccept != "application/vnd.github+json" {
		t.Errorf("Accept = %q", gotAccept)
	}
	if gotAPIVer != "2022-11-28" {
		t.Errorf("API version = %q", gotAPIVer)
	}
}

func TestGitHubGetPRRequiresNumber(t *testing.T) {
	gw := newGitHubTestGateway(http.DefaultClient)
	res, err := gw.githubGetPR(context.Background(), newCallRequest(map[string]any{
		"owner": "o", "repo": "r",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if res == nil || !res.IsError {
		t.Fatalf("expected error result, got %+v", res)
	}
}

func TestGitHubGetPRDiffUsesDiffAccept(t *testing.T) {
	var gotAccept string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAccept = r.Header.Get("Accept")
		_, _ = w.Write([]byte("diff --git a/x b/x"))
	}))
	defer srv.Close()
	githubAPIBaseForTest = srv.URL
	defer func() { githubAPIBaseForTest = "" }()

	gw := newGitHubTestGateway(srv.Client())
	res, err := gw.githubGetPRDiff(context.Background(), newCallRequest(map[string]any{
		"owner": "o", "repo": "r", "number": 7,
	}))
	if err != nil {
		t.Fatalf("call: %v", err)
	}
	if res == nil || res.IsError {
		t.Fatalf("unexpected error: %+v", res)
	}
	if gotAccept != "application/vnd.github.diff" {
		t.Errorf("Accept = %q, want application/vnd.github.diff", gotAccept)
	}
}

func TestGitHubListIssuesStripsPullRequests(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`[
			{"number":1,"title":"real issue"},
			{"number":2,"title":"actually a PR","pull_request":{"url":"x"}},
			{"number":3,"title":"another issue"}
		]`))
	}))
	defer srv.Close()
	githubAPIBaseForTest = srv.URL
	defer func() { githubAPIBaseForTest = "" }()

	gw := newGitHubTestGateway(srv.Client())
	res, err := gw.githubListIssues(context.Background(), newCallRequest(map[string]any{"owner": "o", "repo": "r"}))
	if err != nil {
		t.Fatalf("call: %v", err)
	}
	if res == nil || res.IsError {
		t.Fatalf("unexpected error: %+v", res)
	}
	text := toolResultText(res)
	var out []map[string]any
	if err := json.Unmarshal([]byte(text), &out); err != nil {
		t.Fatalf("decode result %q: %v", text, err)
	}
	if len(out) != 2 {
		t.Fatalf("want 2 issues after PR strip, got %d (%v)", len(out), out)
	}
}

func TestGitHubSearchCodeRequiresQuery(t *testing.T) {
	gw := newGitHubTestGateway(http.DefaultClient)
	res, err := gw.githubSearchCode(context.Background(), newCallRequest(map[string]any{}))
	if err != nil {
		t.Fatal(err)
	}
	if res == nil || !res.IsError {
		t.Fatalf("expected error for missing query, got %+v", res)
	}
}

func TestGitHubCallSurfacesHTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"message":"Bad credentials"}`, http.StatusUnauthorized)
	}))
	defer srv.Close()
	githubAPIBaseForTest = srv.URL
	defer func() { githubAPIBaseForTest = "" }()

	gw := newGitHubTestGateway(srv.Client())
	res, err := gw.githubListPRs(context.Background(), newCallRequest(map[string]any{"owner": "o", "repo": "r"}))
	if err != nil {
		t.Fatalf("call: %v", err)
	}
	if res == nil || !res.IsError {
		t.Fatalf("expected error for 401")
	}
	if !strings.Contains(toolResultText(res), "401") {
		t.Errorf("error should mention 401; got %q", toolResultText(res))
	}
}

func toolResultText(res *mcpgo.CallToolResult) string {
	if res == nil {
		return ""
	}
	for _, c := range res.Content {
		if tc, ok := c.(mcpgo.TextContent); ok {
			return tc.Text
		}
	}
	return ""
}
