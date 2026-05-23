package mcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
)

// approvingEmitter unblocks every prompt with DecisionApproved on a goroutine.
type approvingEmitter struct {
	g *GateService
}

func (a *approvingEmitter) Emit(p GatePrompt) error {
	go a.g.Respond(p.Nonce, DecisionApproved)
	return nil
}

// rejectingEmitter unblocks every prompt with DecisionCancelled.
type rejectingEmitter struct {
	g       *GateService
	prompts []GatePrompt
	mu      sync.Mutex
}

func (r *rejectingEmitter) Emit(p GatePrompt) error {
	r.mu.Lock()
	r.prompts = append(r.prompts, p)
	r.mu.Unlock()
	go r.g.Respond(p.Nonce, DecisionCancelled)
	return nil
}

func gatewayWithGate(client *http.Client, em GatePromptEmitter) (*Gateway, *GateService) {
	gw := newGitHubTestGateway(client)
	gs := NewGateService(em)
	if e, ok := em.(*approvingEmitter); ok {
		e.g = gs
	}
	if e, ok := em.(*rejectingEmitter); ok {
		e.g = gs
	}
	gw.Gate = gs
	return gw, gs
}

func TestGitHubPostReviewApproved(t *testing.T) {
	var sawMethod, sawPath string
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawMethod = r.Method
		sawPath = r.URL.Path
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &gotBody)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":99,"state":"APPROVED"}`))
	}))
	defer srv.Close()
	githubAPIBaseForTest = srv.URL
	defer func() { githubAPIBaseForTest = "" }()

	gw, _ := gatewayWithGate(srv.Client(), &approvingEmitter{})

	res, err := gw.githubPostReview(context.Background(), newCallRequest(map[string]any{
		"owner": "o", "repo": "r", "number": 5, "event": "APPROVE", "body": "lgtm",
	}))
	if err != nil {
		t.Fatalf("call: %v", err)
	}
	if res == nil || res.IsError {
		t.Fatalf("unexpected error result: %+v (text=%q)", res, toolResultText(res))
	}
	if sawMethod != http.MethodPost || sawPath != "/repos/o/r/pulls/5/reviews" {
		t.Errorf("HTTP = %s %s", sawMethod, sawPath)
	}
	if gotBody["event"] != "APPROVE" || gotBody["body"] != "lgtm" {
		t.Errorf("body = %+v", gotBody)
	}
}

func TestGitHubPostReviewRejectedDoesNotHitAPI(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits++
		w.WriteHeader(200)
	}))
	defer srv.Close()
	githubAPIBaseForTest = srv.URL
	defer func() { githubAPIBaseForTest = "" }()

	gw, _ := gatewayWithGate(srv.Client(), &rejectingEmitter{})

	res, err := gw.githubPostReview(context.Background(), newCallRequest(map[string]any{
		"owner": "o", "repo": "r", "number": 5, "event": "APPROVE",
	}))
	if err != nil {
		t.Fatalf("call: %v", err)
	}
	if res == nil || !res.IsError {
		t.Fatalf("expected user_cancelled error result, got %+v", res)
	}
	if !strings.Contains(toolResultText(res), "user_cancelled") {
		t.Errorf("error text = %q", toolResultText(res))
	}
	if hits != 0 {
		t.Errorf("API was hit %d times despite rejection", hits)
	}
}

func TestGitHubPostReviewWithoutGateFailsClosed(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits++
		w.WriteHeader(200)
	}))
	defer srv.Close()
	githubAPIBaseForTest = srv.URL
	defer func() { githubAPIBaseForTest = "" }()

	gw := newGitHubTestGateway(srv.Client())
	// gw.Gate is nil — fail closed.
	res, err := gw.githubPostReview(context.Background(), newCallRequest(map[string]any{
		"owner": "o", "repo": "r", "number": 5, "event": "APPROVE",
	}))
	if err != nil {
		t.Fatalf("call: %v", err)
	}
	if res == nil || !res.IsError {
		t.Fatalf("expected fail-closed user_cancelled, got %+v", res)
	}
	if hits != 0 {
		t.Errorf("API hit despite no gate emitter")
	}
}

func TestGitHubMergePRRiskAndMethod(t *testing.T) {
	var sawMethod, sawPath string
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawMethod = r.Method
		sawPath = r.URL.Path
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &gotBody)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"merged":true,"sha":"abc"}`))
	}))
	defer srv.Close()
	githubAPIBaseForTest = srv.URL
	defer func() { githubAPIBaseForTest = "" }()

	em := &approvingEmitter{}
	gw, _ := gatewayWithGate(srv.Client(), em)

	res, err := gw.githubMergePR(context.Background(), newCallRequest(map[string]any{
		"owner": "o", "repo": "r", "number": 12, "method": "squash",
	}))
	if err != nil {
		t.Fatalf("call: %v", err)
	}
	if res == nil || res.IsError {
		t.Fatalf("unexpected error: %+v", res)
	}
	if sawMethod != http.MethodPut || sawPath != "/repos/o/r/pulls/12/merge" {
		t.Errorf("HTTP = %s %s", sawMethod, sawPath)
	}
	if gotBody["merge_method"] != "squash" {
		t.Errorf("merge_method = %v", gotBody["merge_method"])
	}
}

func TestGitHubCloseIssueReopened(t *testing.T) {
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &gotBody)
		_, _ = w.Write([]byte(`{"state":"open"}`))
	}))
	defer srv.Close()
	githubAPIBaseForTest = srv.URL
	defer func() { githubAPIBaseForTest = "" }()

	gw, _ := gatewayWithGate(srv.Client(), &approvingEmitter{})

	res, err := gw.githubCloseIssue(context.Background(), newCallRequest(map[string]any{
		"owner": "o", "repo": "r", "number": 3, "reason": "reopened",
	}))
	if err != nil {
		t.Fatalf("call: %v", err)
	}
	if res == nil || res.IsError {
		t.Fatalf("unexpected: %+v", res)
	}
	if gotBody["state"] != "open" {
		t.Errorf("reopened should send state=open, got %+v", gotBody)
	}
	if _, present := gotBody["state_reason"]; present {
		t.Errorf("reopened must not send state_reason")
	}
}

func TestGitHubWritesValidateInput(t *testing.T) {
	gw, _ := gatewayWithGate(http.DefaultClient, &approvingEmitter{})

	bad := []struct {
		name string
		fn   func() (*mcpgo.CallToolResult, error)
	}{
		{"post_review missing event", func() (*mcpgo.CallToolResult, error) {
			return gw.githubPostReview(context.Background(), newCallRequest(map[string]any{
				"owner": "o", "repo": "r", "number": 1,
			}))
		}},
		{"post_review COMMENT without body", func() (*mcpgo.CallToolResult, error) {
			return gw.githubPostReview(context.Background(), newCallRequest(map[string]any{
				"owner": "o", "repo": "r", "number": 1, "event": "COMMENT",
			}))
		}},
		{"merge_pr bad method", func() (*mcpgo.CallToolResult, error) {
			return gw.githubMergePR(context.Background(), newCallRequest(map[string]any{
				"owner": "o", "repo": "r", "number": 1, "method": "nope",
			}))
		}},
		{"close_issue bad reason", func() (*mcpgo.CallToolResult, error) {
			return gw.githubCloseIssue(context.Background(), newCallRequest(map[string]any{
				"owner": "o", "repo": "r", "number": 1, "reason": "bogus",
			}))
		}},
		{"comment_issue empty body", func() (*mcpgo.CallToolResult, error) {
			return gw.githubCommentIssue(context.Background(), newCallRequest(map[string]any{
				"owner": "o", "repo": "r", "number": 1, "body": " ",
			}))
		}},
	}
	for _, c := range bad {
		res, err := c.fn()
		if err != nil {
			t.Fatalf("%s: unexpected error: %v", c.name, err)
		}
		if res == nil || !res.IsError {
			t.Errorf("%s: expected validation error, got %+v", c.name, res)
		}
	}
}

func TestWriteGateAuditEvents(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer srv.Close()
	githubAPIBaseForTest = srv.URL
	defer func() { githubAPIBaseForTest = "" }()

	dir := t.TempDir()
	w := NewAuditWriter(dir + "/audit.log")
	gw, _ := gatewayWithGate(srv.Client(), &approvingEmitter{})
	gw.Audit = w

	_, _ = gw.githubCommentIssue(context.Background(), newCallRequest(map[string]any{
		"owner": "o", "repo": "r", "number": 7, "body": "hi",
	}))
	// rejection path → separate audit kind
	gw2, _ := gatewayWithGate(srv.Client(), &rejectingEmitter{})
	gw2.Audit = w
	_, _ = gw2.githubCommentIssue(context.Background(), newCallRequest(map[string]any{
		"owner": "o", "repo": "r", "number": 7, "body": "hi",
	}))

	data, err := readLogLines(w.Path())
	if err != nil {
		t.Fatalf("read log: %v", err)
	}
	if len(data) != 2 {
		t.Fatalf("expected 2 audit events, got %d (%+v)", len(data), data)
	}
	if data[0].Kind != AuditKindMCPWrite || data[0].Outcome != "ok" {
		t.Errorf("approved event = %+v", data[0])
	}
	if data[1].Kind != AuditKindGateCancel || data[1].Outcome != "user_cancelled" {
		t.Errorf("cancelled event = %+v", data[1])
	}
	for _, e := range data {
		if e.ArgsHash == "" {
			t.Errorf("event missing argsHash: %+v", e)
		}
	}
}

func readLogLines(path string) ([]AuditEvent, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var out []AuditEvent
	for _, line := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		if line == "" {
			continue
		}
		var ev AuditEvent
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			return nil, err
		}
		out = append(out, ev)
	}
	return out, nil
}
