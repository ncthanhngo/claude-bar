package main

// E2E smoke test that mirrors the real subagent scenario from issue #21:
//   - Widget side: spawn `csw gate proxy` as a subprocess, bridge its stdio.
//   - MCP side: spin up TWO DialEmitter instances against the same UDS.
//   - Verify both emitters can deliver prompts to the proxy AND receive
//     decisions routed back via the correct nonce.
//
// Run with:  go test -tags sqlite_fts5 -run TestE2E -count=1 ./cmd/csw/...

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/gateipc"
	"github.com/soi/claude-swap-widget/backend/internal/mcp"
)

func TestE2E_TwoMCPServersBothReachWidget(t *testing.T) {
	if os.Getenv("CSW_E2E") == "" {
		t.Skip("set CSW_E2E=1 to run end-to-end smoke test")
	}

	cswBin := filepath.Join("..", "..", "..", "release", "ClaudeBar.app", "Contents", "Resources", "csw")
	if _, err := os.Stat(cswBin); err != nil {
		t.Skipf("freshly built csw not found at %s: %v", cswBin, err)
	}

	sock := filepath.Join(os.TempDir(), fmt.Sprintf("cb-e2e-%d.sock", time.Now().UnixNano()))
	defer os.Remove(sock)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cmd := exec.CommandContext(ctx, cswBin, "gate", "proxy", "--socket", sock)
	stdin, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatalf("start proxy: %v", err)
	}
	defer func() {
		_ = stdin.Close()
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	}()

	r := bufio.NewReader(stdout)
	// First line from proxy = synthetic hello.
	if line, err := r.ReadString('\n'); err != nil {
		t.Fatalf("read proxy hello: %v", err)
	} else {
		var e gateipc.Envelope
		_ = json.Unmarshal([]byte(line), &e)
		if e.Kind != gateipc.EnvelopeHello {
			t.Fatalf("expected hello from proxy, got %q", line)
		}
	}

	// Spin up two MCP-side dialers. Each binds its own GateService (mirrors
	// the real layout where every `csw mcp serve` process has its own).
	gateA := mcp.NewGateService(nil)
	emA := gateipc.NewDialEmitter(sock, gateA)
	gateA.Emitter = emA
	emA.Start(ctx)

	gateB := mcp.NewGateService(nil)
	emB := gateipc.NewDialEmitter(sock, gateB)
	gateB.Emitter = emB
	emB.Start(ctx)

	// Forward decision envelopes from the test back to whichever GateService
	// owns the nonce — neither side knows about the other, so we tag prompts
	// with a side prefix and route by it.
	var (
		mu        sync.Mutex
		nonceSide = map[string]string{} // nonce -> "A" or "B"
	)
	respond := func(nonce, decision string) {
		env := gateipc.Envelope{Kind: gateipc.EnvelopeRespond, Nonce: nonce, Decision: decision}
		b, _ := json.Marshal(env)
		_, _ = stdin.Write(append(b, '\n'))
	}

	// Reader: each prompt line from the proxy → auto-approve. The proxy
	// already injected the nonce; we just echo it back.
	go func() {
		for {
			line, err := r.ReadString('\n')
			if err != nil {
				return
			}
			var e gateipc.Envelope
			if err := json.Unmarshal([]byte(line), &e); err != nil || e.Kind != gateipc.EnvelopePrompt || e.Prompt == nil {
				continue
			}
			respond(e.Prompt.Nonce, "approved")
		}
	}()

	// Both dialers need to handshake before we fire prompts.
	time.Sleep(300 * time.Millisecond)

	type result struct {
		side string
		dec  mcp.Decision
		err  error
	}
	resCh := make(chan result, 2)

	emitFrom := func(side string, gate *mcp.GateService) {
		nonce := side + "-" + fmt.Sprint(time.Now().UnixNano())
		mu.Lock()
		nonceSide[nonce] = side
		mu.Unlock()
		d, err := gate.AwaitApproval(ctx, mcp.GatePrompt{Nonce: nonce, Tool: "cb_slack_post_message"})
		resCh <- result{side: side, dec: d, err: err}
	}

	go emitFrom("A", gateA)
	go emitFrom("B", gateB)

	deadline := time.After(8 * time.Second)
	var seen []result
	for i := 0; i < 2; i++ {
		select {
		case rr := <-resCh:
			if rr.err != nil {
				t.Fatalf("AwaitApproval from %s: %v", rr.side, rr.err)
			}
			if rr.dec != mcp.DecisionApproved {
				t.Fatalf("AwaitApproval from %s returned %v, want approved", rr.side, rr.dec)
			}
			seen = append(seen, rr)
		case <-deadline:
			t.Fatalf("only %d/%d sides returned (issue #21 still present?)", len(seen), 2)
		}
	}
	t.Logf("both sides approved: %+v", seen)
}
