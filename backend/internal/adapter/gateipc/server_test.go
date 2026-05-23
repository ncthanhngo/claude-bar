package gateipc

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
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

func dial(t *testing.T, path string) net.Conn {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		c, err := net.Dial("unix", path)
		if err == nil {
			return c
		}
		if time.Now().After(deadline) {
			t.Fatalf("dial: %v", err)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestServerFlushesQueueAndForwardsDecision(t *testing.T) {
	sock := shortSock(t)
	gate := mcp.NewGateService(nil)
	srv := NewServer(sock, gate)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := srv.Start(ctx); err != nil {
		t.Fatalf("start: %v", err)
	}

	// AwaitApproval blocks; run it on a goroutine and queue a prompt that
	// will only be flushed after the widget connects.
	done := make(chan mcp.Decision, 1)
	go func() {
		d, _ := gate.AwaitApproval(ctx, mcp.GatePrompt{Tool: "cb_github_post_review", Risk: mcp.RiskLow})
		done <- d
	}()

	// Subscriber connects, reads hello + prompt.
	conn := dial(t, sock)
	defer conn.Close()
	r := bufio.NewScanner(conn)

	// hello
	if !r.Scan() {
		t.Fatalf("missing hello: %v", r.Err())
	}
	var hello Envelope
	if err := json.Unmarshal(r.Bytes(), &hello); err != nil {
		t.Fatalf("decode hello: %v", err)
	}
	if hello.Kind != EnvelopeHello {
		t.Fatalf("expected hello, got %v", hello.Kind)
	}

	// prompt
	if !r.Scan() {
		t.Fatalf("missing prompt: %v", r.Err())
	}
	var prompt Envelope
	if err := json.Unmarshal(r.Bytes(), &prompt); err != nil {
		t.Fatalf("decode prompt: %v", err)
	}
	if prompt.Kind != EnvelopePrompt || prompt.Prompt == nil {
		t.Fatalf("expected prompt, got %+v", prompt)
	}
	nonce := prompt.Prompt.Nonce

	// Respond approved.
	resp := Envelope{Kind: EnvelopeRespond, Nonce: nonce, Decision: "approved"}
	b, _ := json.Marshal(resp)
	if _, err := conn.Write(append(b, '\n')); err != nil {
		t.Fatalf("write resp: %v", err)
	}

	select {
	case d := <-done:
		if d != mcp.DecisionApproved {
			t.Fatalf("decision = %v, want approved", d)
		}
	case <-time.After(time.Second):
		t.Fatal("AwaitApproval did not return after Respond")
	}
}

func TestServerSecondSubscriberReplacesFirst(t *testing.T) {
	sock := shortSock(t)
	gate := mcp.NewGateService(nil)
	srv := NewServer(sock, gate)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := srv.Start(ctx); err != nil {
		t.Fatalf("start: %v", err)
	}

	a := dial(t, sock)
	defer a.Close()
	// Drain hello.
	_, _ = bufio.NewReader(a).ReadString('\n')

	b := dial(t, sock)
	defer b.Close()
	// b should also see a hello.
	if line, err := bufio.NewReader(b).ReadString('\n'); err != nil || line == "" {
		t.Fatalf("second subscriber should get hello: %v %q", err, line)
	}

	// Emit a prompt; should arrive on b, not a.
	go func() { _, _ = gate.AwaitApproval(ctx, mcp.GatePrompt{Tool: "x"}) }()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		_ = b.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
		buf := make([]byte, 1024)
		n, _ := b.Read(buf)
		if n > 0 {
			return // success
		}
	}
	t.Fatal("second subscriber never received prompt")
}
