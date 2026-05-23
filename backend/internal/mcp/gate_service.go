package mcp

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"sync"
	"time"
)

// Origin is where a tool call originated. The trust-capture path (Phase 8)
// uses Origin to gate auto-confirm rules — only OriginCapture is eligible.
// Enforcement lives in GateService, not at tool call sites (RT Finding 13).
type Origin int

const (
	OriginLLM Origin = iota
	OriginCapture
	OriginRowAction
)

// Risk drives the gate presentation: chip for Low/Medium, modal for
// Destructive, amber inline for ReadSensitive. Backend (not LLM) sets this
// per Tool — the LLM cannot downgrade.
type Risk int

const (
	RiskLow Risk = iota
	RiskMedium
	RiskDestructive
	RiskReadSensitive
)

// Decision is the widget's response to a gate prompt.
type Decision int

const (
	DecisionPending Decision = iota
	DecisionApproved
	DecisionCancelled
	DecisionTimeout
)

// GatePrompt is what the gate service emits to the widget. Args are the
// resolved arguments (not the raw LLM prompt) — what the user sees must match
// what executes.
type GatePrompt struct {
	Nonce     string         `json:"nonce"`
	Tool      string         `json:"tool"`
	Risk      Risk           `json:"risk"`
	Origin    Origin         `json:"origin"`
	Summary   string         `json:"summary"`
	Args      map[string]any `json:"args"`
	Account   string         `json:"account,omitempty"`
	CreatedAt time.Time      `json:"createdAt"`
}

// GatePromptEmitter delivers gate prompts to the widget. The MCP layer never
// implements this directly — callers wire in an IPC bridge. A nil emitter
// causes AwaitApproval to immediately return DecisionTimeout, which is the
// safe fail-closed default for unwired environments (CLI usage, tests).
type GatePromptEmitter interface {
	Emit(GatePrompt) error
}

// ErrGateNoEmitter means no emitter is wired — every write call fails closed.
var ErrGateNoEmitter = errors.New("gate: no emitter configured")

// GateService coordinates write-tool approval. It is NOT registered as an MCP
// tool — LLMs cannot call into it. Widget responds via an internal IPC path.
//
// AwaitApproval blocks on a per-nonce channel; Respond unblocks it. 30-second
// hard timeout returns DecisionTimeout.
type GateService struct {
	Emitter GatePromptEmitter
	Timeout time.Duration

	mu      sync.Mutex
	pending map[string]chan Decision
}

// NewGateService builds a service with the given emitter and a 30s default
// timeout.
func NewGateService(em GatePromptEmitter) *GateService {
	return &GateService{
		Emitter: em,
		Timeout: 30 * time.Second,
		pending: make(map[string]chan Decision),
	}
}

// AwaitApproval emits a gate prompt, then blocks until the widget responds,
// the timeout fires, or ctx is cancelled. The nonce is generated server-side
// and never crosses the MCP boundary — only the internal widget↔backend IPC
// sees it.
func (s *GateService) AwaitApproval(ctx context.Context, p GatePrompt) (Decision, error) {
	if s.Emitter == nil {
		return DecisionTimeout, ErrGateNoEmitter
	}
	nonce, err := newNonce()
	if err != nil {
		return DecisionTimeout, fmt.Errorf("gate nonce: %w", err)
	}
	p.Nonce = nonce
	if p.CreatedAt.IsZero() {
		p.CreatedAt = time.Now().UTC()
	}

	ch := make(chan Decision, 1)
	s.mu.Lock()
	s.pending[nonce] = ch
	s.mu.Unlock()
	defer s.clear(nonce)

	if err := s.Emitter.Emit(p); err != nil {
		return DecisionTimeout, fmt.Errorf("gate emit: %w", err)
	}

	timeout := s.Timeout
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()

	select {
	case d := <-ch:
		return d, nil
	case <-timer.C:
		return DecisionTimeout, nil
	case <-ctx.Done():
		return DecisionCancelled, ctx.Err()
	}
}

// Respond unblocks a waiting AwaitApproval call. Unknown nonces are ignored —
// they can result from a widget responding after a timeout or after a backend
// restart, both of which are safe to drop.
func (s *GateService) Respond(nonce string, d Decision) {
	s.mu.Lock()
	ch, ok := s.pending[nonce]
	s.mu.Unlock()
	if !ok {
		return
	}
	select {
	case ch <- d:
	default:
	}
}

// PendingCount is for diagnostics / tests.
func (s *GateService) PendingCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.pending)
}

func (s *GateService) clear(nonce string) {
	s.mu.Lock()
	delete(s.pending, nonce)
	s.mu.Unlock()
}

func newNonce() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}
