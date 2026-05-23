package mcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestClickUpCreateTaskApproved(t *testing.T) {
	var gotPath string
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &gotBody)
		_, _ = w.Write([]byte(`{"id":"t1","name":"x"}`))
	}))
	defer srv.Close()
	oldBase := clickupAPIBase
	clickupAPIBase = srv.URL
	defer func() { clickupAPIBase = oldBase }()

	gw := newClickUpTestGateway(srv.Client())
	gw.Gate = NewGateService(nil)
	em := &approvingEmitter{g: gw.Gate}
	gw.Gate.Emitter = em

	res, err := gw.clickupCreateTask(context.Background(), newCallRequest(map[string]any{
		"list_id": "L1", "name": "fix login", "priority": "high",
	}))
	if err != nil {
		t.Fatalf("call: %v", err)
	}
	if res == nil || res.IsError {
		t.Fatalf("unexpected: %+v text=%q", res, toolResultText(res))
	}
	if gotPath != "/list/L1/task" {
		t.Errorf("path = %q", gotPath)
	}
	if gotBody["name"] != "fix login" {
		t.Errorf("body name = %v", gotBody["name"])
	}
	if v, _ := gotBody["priority"].(float64); int(v) != 2 {
		t.Errorf("priority should be 2 (high), got %v", gotBody["priority"])
	}
}

func TestClickUpUpdateStatusRisk(t *testing.T) {
	// "completed" should trip RiskMedium → still proceeds with approval, but
	// we assert the prompt carries the elevated risk.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"id":"t1"}`))
	}))
	defer srv.Close()
	oldBase := clickupAPIBase
	clickupAPIBase = srv.URL
	defer func() { clickupAPIBase = oldBase }()

	gw := newClickUpTestGateway(srv.Client())
	em := &recordingEmitter{}
	gw.Gate = NewGateService(em)
	em.g = gw.Gate

	_, _ = gw.clickupUpdateTaskStatus(context.Background(), newCallRequest(map[string]any{
		"task_id": "T1", "status": "completed",
	}))
	if len(em.prompts) != 1 {
		t.Fatalf("expected 1 prompt, got %d", len(em.prompts))
	}
	if em.prompts[0].Risk != RiskMedium {
		t.Errorf("risk = %v, want RiskMedium for status=completed", em.prompts[0].Risk)
	}

	em.prompts = nil
	_, _ = gw.clickupUpdateTaskStatus(context.Background(), newCallRequest(map[string]any{
		"task_id": "T1", "status": "in progress",
	}))
	if em.prompts[0].Risk != RiskLow {
		t.Errorf("risk = %v, want RiskLow for status=in progress", em.prompts[0].Risk)
	}
}

func TestClickUpAssignParsesCSV(t *testing.T) {
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &gotBody)
		_, _ = w.Write([]byte(`{"id":"T1"}`))
	}))
	defer srv.Close()
	oldBase := clickupAPIBase
	clickupAPIBase = srv.URL
	defer func() { clickupAPIBase = oldBase }()

	gw := newClickUpTestGateway(srv.Client())
	gw.Gate = NewGateService(nil)
	em := &approvingEmitter{g: gw.Gate}
	gw.Gate.Emitter = em

	res, err := gw.clickupAssign(context.Background(), newCallRequest(map[string]any{
		"task_id": "T1", "add": "100, 200", "remove": "300",
	}))
	if err != nil || res.IsError {
		t.Fatalf("call failed: %+v err=%v", res, err)
	}
	assignees, ok := gotBody["assignees"].(map[string]any)
	if !ok {
		t.Fatalf("missing assignees in body: %+v", gotBody)
	}
	add, _ := assignees["add"].([]any)
	rem, _ := assignees["rem"].([]any)
	if len(add) != 2 || len(rem) != 1 {
		t.Errorf("add=%v rem=%v", add, rem)
	}
}

func TestClickUpAssignRequiresAddOrRemove(t *testing.T) {
	gw := newClickUpTestGateway(http.DefaultClient)
	gw.Gate = NewGateService(&approvingEmitter{})
	res, err := gw.clickupAssign(context.Background(), newCallRequest(map[string]any{"task_id": "T1"}))
	if err != nil {
		t.Fatal(err)
	}
	if res == nil || !res.IsError {
		t.Fatalf("expected error for missing add/remove")
	}
}

func TestClickUpWriteRejectionDoesNotHitAPI(t *testing.T) {
	var hits int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits++
		w.WriteHeader(200)
	}))
	defer srv.Close()
	oldBase := clickupAPIBase
	clickupAPIBase = srv.URL
	defer func() { clickupAPIBase = oldBase }()

	gw := newClickUpTestGateway(srv.Client())
	em := &rejectingEmitter{}
	gw.Gate = NewGateService(em)
	em.g = gw.Gate

	res, _ := gw.clickupAddComment(context.Background(), newCallRequest(map[string]any{
		"task_id": "T1", "body": "hello",
	}))
	if res == nil || !res.IsError {
		t.Fatalf("expected user_cancelled, got %+v", res)
	}
	if hits != 0 {
		t.Errorf("API hit %d times despite rejection", hits)
	}
}

// recordingEmitter captures prompts AND auto-approves so flow continues.
type recordingEmitter struct {
	g       *GateService
	prompts []GatePrompt
}

func (r *recordingEmitter) Emit(p GatePrompt) error {
	r.prompts = append(r.prompts, p)
	go r.g.Respond(p.Nonce, DecisionApproved)
	return nil
}
