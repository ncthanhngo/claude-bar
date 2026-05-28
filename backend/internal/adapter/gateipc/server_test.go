package gateipc

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/mcp"
)

// shortSock returns a UDS path short enough for macOS (104-char sun_path
// limit). t.TempDir() under /var/folders/... blows past that limit.
func shortSock(t *testing.T) string {
	t.Helper()
	p := filepath.Join(os.TempDir(), fmt.Sprintf("cb-gate-%d.sock", time.Now().UnixNano()))
	if len(p) > 100 {
		p = filepath.Join("/tmp", fmt.Sprintf("cb-%d.sock", time.Now().UnixNano()))
	}
	t.Cleanup(func() { _ = os.Remove(p) })
	return p
}

// handshakeClient mimics the MCP-side dialer just enough for tests: reads
// hello, writes ready, returns the connection ready for prompt/respond
// envelopes.
func handshakeClient(t *testing.T, path string) (net.Conn, *bufio.Reader) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	var conn net.Conn
	var err error
	for {
		conn, err = net.Dial("unix", path)
		if err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("dial: %v", err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	r := bufio.NewReader(conn)
	line, err := r.ReadString('\n')
	if err != nil {
		t.Fatalf("read hello: %v", err)
	}
	var hello Envelope
	if err := json.Unmarshal([]byte(line), &hello); err != nil {
		t.Fatalf("decode hello: %v", err)
	}
	if hello.Kind != EnvelopeHello {
		t.Fatalf("expected hello, got %v", hello.Kind)
	}
	ready := Envelope{Kind: EnvelopeReady}
	b, _ := json.Marshal(ready)
	if _, err := conn.Write(append(b, '\n')); err != nil {
		t.Fatalf("write ready: %v", err)
	}
	return conn, r
}

// TestServerForwardsPromptAndRoutesDecision is the happy-path smoke test:
// one MCP-server client emits a prompt, the server invokes onPrompt, and
// Respond routes a decision back over the same connection.
func TestServerForwardsPromptAndRoutesDecision(t *testing.T) {
	sock := shortSock(t)

	var got []mcp.GatePrompt
	var promptMu sync.Mutex
	srv := NewServer(sock, func(p mcp.GatePrompt) {
		promptMu.Lock()
		got = append(got, p)
		promptMu.Unlock()
	})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := srv.Start(ctx); err != nil {
		t.Fatalf("start: %v", err)
	}

	conn, r := handshakeClient(t, sock)
	defer conn.Close()

	prompt := mcp.GatePrompt{Nonce: "nonce-A", Tool: "cb_github_post_review", Risk: mcp.RiskLow}
	env := Envelope{Kind: EnvelopePrompt, Prompt: &prompt}
	b, _ := json.Marshal(env)
	if _, err := conn.Write(append(b, '\n')); err != nil {
		t.Fatalf("write prompt: %v", err)
	}

	// Wait for onPrompt to fire.
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		promptMu.Lock()
		n := len(got)
		promptMu.Unlock()
		if n > 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	promptMu.Lock()
	if len(got) != 1 || got[0].Nonce != "nonce-A" {
		t.Fatalf("expected one prompt with nonce-A, got %+v", got)
	}
	promptMu.Unlock()

	srv.Respond("nonce-A", "approved")

	line, err := r.ReadString('\n')
	if err != nil {
		t.Fatalf("read decision: %v", err)
	}
	var dec Envelope
	if err := json.Unmarshal([]byte(line), &dec); err != nil {
		t.Fatalf("decode decision: %v", err)
	}
	if dec.Kind != EnvelopeRespond || dec.Nonce != "nonce-A" || dec.Decision != "approved" {
		t.Fatalf("unexpected decision envelope: %+v", dec)
	}
}

// TestServerRoutesDecisionsToOriginatingClient is the regression test for
// issue #21: two MCP-server clients connect concurrently (simulating a main
// session + a subagent), each emits a prompt, and Respond must route each
// decision back to the client that originated the matching nonce.
func TestServerRoutesDecisionsToOriginatingClient(t *testing.T) {
	sock := shortSock(t)
	srv := NewServer(sock, func(p mcp.GatePrompt) {})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := srv.Start(ctx); err != nil {
		t.Fatalf("start: %v", err)
	}

	connA, rA := handshakeClient(t, sock)
	defer connA.Close()
	connB, rB := handshakeClient(t, sock)
	defer connB.Close()

	emit := func(c net.Conn, nonce string) {
		p := mcp.GatePrompt{Nonce: nonce, Tool: "cb_slack_post_message"}
		env := Envelope{Kind: EnvelopePrompt, Prompt: &p}
		b, _ := json.Marshal(env)
		if _, err := c.Write(append(b, '\n')); err != nil {
			t.Fatalf("emit %s: %v", nonce, err)
		}
	}
	emit(connA, "from-A")
	emit(connB, "from-B")

	// Give the server a beat to register both nonces.
	time.Sleep(50 * time.Millisecond)

	srv.Respond("from-A", "approved")
	srv.Respond("from-B", "cancelled")

	read := func(r *bufio.Reader) Envelope {
		_ = connA.SetReadDeadline(time.Now().Add(time.Second))
		_ = connB.SetReadDeadline(time.Now().Add(time.Second))
		line, err := r.ReadString('\n')
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		var e Envelope
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			t.Fatalf("decode: %v", err)
		}
		return e
	}
	gotA := read(rA)
	gotB := read(rB)
	if gotA.Nonce != "from-A" || gotA.Decision != "approved" {
		t.Fatalf("A got wrong envelope: %+v", gotA)
	}
	if gotB.Nonce != "from-B" || gotB.Decision != "cancelled" {
		t.Fatalf("B got wrong envelope: %+v", gotB)
	}
}

// TestDialEmitterRoundTrip exercises the dialer + server end-to-end: a
// dial-emitter wired into a real GateService should successfully emit a
// prompt, receive the response, and unblock AwaitApproval.
func TestDialEmitterRoundTrip(t *testing.T) {
	sock := shortSock(t)

	// Widget-side: listener + a goroutine that auto-approves every prompt
	// by echoing the nonce back via Respond.
	srv := NewServer(sock, nil)
	srv.onPrompt = func(p mcp.GatePrompt) { srv.Respond(p.Nonce, "approved") }

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := srv.Start(ctx); err != nil {
		t.Fatalf("start: %v", err)
	}

	gate := mcp.NewGateService(nil)
	emitter := NewDialEmitter(sock, gate)
	gate.Emitter = emitter
	emitter.Start(ctx)

	// Wait for the dialer to handshake.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if srv.ActiveClientCount() > 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if srv.ActiveClientCount() == 0 {
		t.Fatal("dialer never connected")
	}
	// Small extra wait for the ready handshake to complete server-side.
	time.Sleep(50 * time.Millisecond)

	d, err := gate.AwaitApproval(ctx, mcp.GatePrompt{Tool: "cb_clickup_add_comment"})
	if err != nil {
		t.Fatalf("AwaitApproval: %v", err)
	}
	if d != mcp.DecisionApproved {
		t.Fatalf("decision = %v, want approved", d)
	}
}
