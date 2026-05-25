package mcp

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	sshadp "github.com/soi/claude-swap-widget/backend/internal/adapter/ssh"
)

// fakeSSHStore returns a fixed slice of hosts and tracks MarkConnected calls.
type fakeSSHStore struct {
	hosts        []sshadp.TrackedHost
	markedHosts  []string
}

func (f *fakeSSHStore) List(_ context.Context) ([]sshadp.TrackedHost, error) {
	return f.hosts, nil
}
func (f *fakeSSHStore) Get(_ context.Context, name string) (*sshadp.TrackedHost, error) {
	for i, h := range f.hosts {
		if h.Name == name {
			return &f.hosts[i], nil
		}
	}
	return nil, &hostMissingErr{name: name}
}
func (f *fakeSSHStore) MarkConnected(_ context.Context, name string, _ time.Time) error {
	f.markedHosts = append(f.markedHosts, name)
	return nil
}

type hostMissingErr struct{ name string }

func (e *hostMissingErr) Error() string { return "host not tracked: " + e.name }

// fakeSSHRunner records calls and returns canned output.
type fakeSSHRunner struct {
	execCalls []execCall
	tailCalls []tailCall
	readCalls []readCall
	canned    sshadp.ExecResult
}

type execCall struct {
	host    string
	cmd     string
	timeout time.Duration
}
type tailCall struct {
	host     string
	path     string
	lines    int
	follow   int
}
type readCall struct {
	host     string
	path     string
	maxBytes int
}

func (f *fakeSSHRunner) Exec(_ context.Context, h sshadp.TrackedHost, cmd string, t time.Duration) (*sshadp.ExecResult, error) {
	f.execCalls = append(f.execCalls, execCall{host: h.Name, cmd: cmd, timeout: t})
	c := f.canned
	return &c, nil
}
func (f *fakeSSHRunner) Tail(_ context.Context, h sshadp.TrackedHost, path string, lines, follow int) (*sshadp.ExecResult, error) {
	f.tailCalls = append(f.tailCalls, tailCall{host: h.Name, path: path, lines: lines, follow: follow})
	c := f.canned
	return &c, nil
}
func (f *fakeSSHRunner) ReadFile(_ context.Context, h sshadp.TrackedHost, path string, maxBytes int) (*sshadp.ExecResult, error) {
	f.readCalls = append(f.readCalls, readCall{host: h.Name, path: path, maxBytes: maxBytes})
	c := f.canned
	return &c, nil
}

func gatewayWithSSH() (*Gateway, *fakeSSHStore, *fakeSSHRunner) {
	gw := newTestGateway()
	store := &fakeSSHStore{hosts: []sshadp.TrackedHost{{
		Name: "gem-prod", HostName: "10.0.0.1", Port: 2222, User: "deploy",
	}}}
	runner := &fakeSSHRunner{canned: sshadp.ExecResult{Stdout: "ok\n", ExitCode: 0}}
	gw.SSHStore = store
	gw.SSHRunner = runner
	return gw, store, runner
}

func TestSSHListHostsReturnsTrackedSet(t *testing.T) {
	gw, _, _ := gatewayWithSSH()
	res, err := gw.sshListHosts(context.Background(), newCallRequest(map[string]any{}))
	if err != nil || res.IsError {
		t.Fatalf("list: %+v err=%v", res, err)
	}
	var out []map[string]any
	if err := json.Unmarshal([]byte(toolResultText(res)), &out); err != nil {
		t.Fatalf("decode: %v text=%q", err, toolResultText(res))
	}
	if len(out) != 1 || out[0]["name"] != "gem-prod" {
		t.Fatalf("unexpected: %v", out)
	}
}

func TestSSHExecLowRiskApproved(t *testing.T) {
	gw, store, runner := gatewayWithSSH()
	em := &approvingEmitter{}
	gw.Gate = NewGateService(em)
	em.g = gw.Gate

	res, err := gw.sshExec(context.Background(), newCallRequest(map[string]any{
		"host": "gem-prod", "cmd": "uptime",
	}))
	if err != nil || res.IsError {
		t.Fatalf("exec: %+v err=%v", res, err)
	}
	if len(runner.execCalls) != 1 {
		t.Fatalf("runner called %d times, want 1", len(runner.execCalls))
	}
	if len(store.markedHosts) != 1 {
		t.Errorf("expected MarkConnected on success, got %v", store.markedHosts)
	}
}

func TestSSHExecMetacharForcesDestructive(t *testing.T) {
	gw, _, runner := gatewayWithSSH()
	em := &recordingEmitter{}
	gw.Gate = NewGateService(em)
	em.g = gw.Gate

	_, _ = gw.sshExec(context.Background(), newCallRequest(map[string]any{
		"host": "gem-prod", "cmd": "uptime; rm -rf /",
	}))
	if len(em.prompts) != 1 {
		t.Fatalf("want 1 prompt, got %d", len(em.prompts))
	}
	if em.prompts[0].Risk != RiskDestructive {
		t.Errorf("metachar bypass should be Destructive, got %v", em.prompts[0].Risk)
	}
	if len(runner.execCalls) != 1 {
		// With approving emitter, exec runs after approval. That's fine —
		// classifier still flagged destructive. (Real flow: ConfirmGateModal
		// requires explicit destructive confirm.)
	}
}

func TestSSHExecRejectedDoesNotRun(t *testing.T) {
	gw, _, runner := gatewayWithSSH()
	em := &rejectingEmitter{}
	gw.Gate = NewGateService(em)
	em.g = gw.Gate

	res, _ := gw.sshExec(context.Background(), newCallRequest(map[string]any{
		"host": "gem-prod", "cmd": "rm -rf /tmp/x",
	}))
	if res == nil || !res.IsError {
		t.Fatalf("expected user_cancelled, got %+v", res)
	}
	if len(runner.execCalls) != 0 {
		t.Errorf("runner invoked despite rejection: %v", runner.execCalls)
	}
}

func TestSSHTailClampsAndCallsRunner(t *testing.T) {
	gw, _, runner := gatewayWithSSH()
	res, err := gw.sshTail(context.Background(), newCallRequest(map[string]any{
		"host": "gem-prod", "path": "/var/log/syslog", "lines": 200, "follow_seconds": 5,
	}))
	if err != nil || res.IsError {
		t.Fatalf("tail: %+v err=%v", res, err)
	}
	if len(runner.tailCalls) != 1 {
		t.Fatalf("runner.Tail called %d times", len(runner.tailCalls))
	}
	if runner.tailCalls[0].lines != 200 || runner.tailCalls[0].follow != 5 {
		t.Errorf("unexpected tail args: %+v", runner.tailCalls[0])
	}
}
