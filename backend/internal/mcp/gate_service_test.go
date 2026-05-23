package mcp

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

type fakeEmitter struct {
	mu       sync.Mutex
	prompts  []GatePrompt
	emitErr  error
}

func (f *fakeEmitter) Emit(p GatePrompt) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.emitErr != nil {
		return f.emitErr
	}
	f.prompts = append(f.prompts, p)
	return nil
}

func (f *fakeEmitter) lastNonce(t *testing.T) string {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		f.mu.Lock()
		n := len(f.prompts)
		f.mu.Unlock()
		if n > 0 {
			f.mu.Lock()
			defer f.mu.Unlock()
			return f.prompts[len(f.prompts)-1].Nonce
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatal("emitter never received a prompt")
	return ""
}

func TestGateAwaitApprovalApproved(t *testing.T) {
	em := &fakeEmitter{}
	g := NewGateService(em)

	resultCh := make(chan Decision, 1)
	go func() {
		d, err := g.AwaitApproval(context.Background(), GatePrompt{Tool: "cb_github_post_review", Risk: RiskLow})
		if err != nil {
			t.Errorf("unexpected error: %v", err)
		}
		resultCh <- d
	}()

	nonce := em.lastNonce(t)
	g.Respond(nonce, DecisionApproved)
	select {
	case d := <-resultCh:
		if d != DecisionApproved {
			t.Fatalf("decision = %v, want approved", d)
		}
	case <-time.After(time.Second):
		t.Fatal("await did not return after Respond")
	}
	if got := g.PendingCount(); got != 0 {
		t.Fatalf("pending should be cleared, got %d", got)
	}
}

func TestGateAwaitApprovalTimeout(t *testing.T) {
	em := &fakeEmitter{}
	g := NewGateService(em)
	g.Timeout = 30 * time.Millisecond

	d, err := g.AwaitApproval(context.Background(), GatePrompt{Tool: "cb_github_merge_pr", Risk: RiskDestructive})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if d != DecisionTimeout {
		t.Fatalf("decision = %v, want timeout", d)
	}
	if got := g.PendingCount(); got != 0 {
		t.Fatalf("pending leak after timeout: %d", got)
	}
}

func TestGateAwaitApprovalCancelled(t *testing.T) {
	em := &fakeEmitter{}
	g := NewGateService(em)
	g.Timeout = time.Second

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(20 * time.Millisecond)
		cancel()
	}()
	d, err := g.AwaitApproval(ctx, GatePrompt{Tool: "cb_github_comment_issue", Risk: RiskLow})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
	if d != DecisionCancelled {
		t.Fatalf("decision = %v, want cancelled", d)
	}
}

func TestGateRespondUnknownNonceIsIgnored(t *testing.T) {
	em := &fakeEmitter{}
	g := NewGateService(em)
	g.Respond("nope", DecisionApproved) // must not panic
}

func TestGateAwaitWithoutEmitterFailsClosed(t *testing.T) {
	g := NewGateService(nil)
	d, err := g.AwaitApproval(context.Background(), GatePrompt{Tool: "cb_github_merge_pr"})
	if !errors.Is(err, ErrGateNoEmitter) {
		t.Fatalf("err = %v, want ErrGateNoEmitter", err)
	}
	if d != DecisionTimeout {
		t.Fatalf("decision = %v, want timeout (fail-closed)", d)
	}
}

func TestGateNonceIsUniquePerCall(t *testing.T) {
	em := &fakeEmitter{}
	g := NewGateService(em)
	g.Timeout = 20 * time.Millisecond
	for i := 0; i < 5; i++ {
		_, _ = g.AwaitApproval(context.Background(), GatePrompt{Tool: "x"})
	}
	em.mu.Lock()
	defer em.mu.Unlock()
	seen := make(map[string]bool)
	for _, p := range em.prompts {
		if p.Nonce == "" {
			t.Fatalf("empty nonce")
		}
		if seen[p.Nonce] {
			t.Fatalf("duplicate nonce %q", p.Nonce)
		}
		seen[p.Nonce] = true
	}
}
