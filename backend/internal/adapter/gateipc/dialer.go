package gateipc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/mcp"
)

// DialEmitter is the MCP-server side of the gate IPC. It dials the widget's
// UDS listener (run by `csw gate proxy`), sends prompt envelopes outbound,
// and routes inbound decision envelopes back to the local mcp.GateService.
//
// This flipped direction (MCP dials, widget listens) is what allows multiple
// concurrent `csw mcp serve` instances — one per claude session, including
// subagents — to all reach the same widget. The previous design had MCP
// servers race to bind a fixed socket path; only the winner's prompts
// reached the widget, the rest timed out (issue #21).
type DialEmitter struct {
	socketPath string
	gate       *mcp.GateService

	mu     sync.Mutex
	conn   net.Conn
	ready  bool      // widget answered ready after our hello
	enc    *json.Encoder
	dialCh chan struct{} // closed once a dial attempt is in flight
}

// NewDialEmitter constructs an emitter that will lazily connect to socketPath
// on first Emit. Pair this with gate.Emitter = emitter to wire it into the
// MCP server.
func NewDialEmitter(socketPath string, gate *mcp.GateService) *DialEmitter {
	return &DialEmitter{socketPath: socketPath, gate: gate}
}

// Start begins maintaining a connection to the widget in the background.
// Returns immediately; the actual dial happens asynchronously with retry.
// Cancelling ctx tears the connection down.
func (d *DialEmitter) Start(ctx context.Context) {
	go d.connectLoop(ctx)
}

// Emit sends a prompt envelope to the widget. If no widget is connected
// yet, the call returns ErrGateNoEmitter quickly so the caller fails
// closed instead of blocking forever — gate.go upgrades this to
// DecisionTimeout, which is the same observable behaviour as the legacy
// path when a widget never connected.
func (d *DialEmitter) Emit(p mcp.GatePrompt) error {
	d.mu.Lock()
	conn := d.conn
	enc := d.enc
	ready := d.ready
	d.mu.Unlock()
	if conn == nil || enc == nil || !ready {
		return errNoWidget
	}
	env := Envelope{Kind: EnvelopePrompt, Prompt: &p}
	if err := encodeWithDeadline(conn, enc, env); err != nil {
		d.dropConnection(conn)
		return errNoWidget
	}
	return nil
}

var errNoWidget = errors.New("gateipc: no widget connected")

// connectLoop maintains a single connection to socketPath. On each fresh
// connection it expects a hello, sends ready, then reads decision envelopes
// in a loop until the connection drops; then it backs off and re-dials.
func (d *DialEmitter) connectLoop(ctx context.Context) {
	backoff := 200 * time.Millisecond
	maxBackoff := 5 * time.Second
	for {
		if ctx.Err() != nil {
			return
		}
		conn, err := net.Dial("unix", d.socketPath)
		if err != nil {
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			if backoff < maxBackoff {
				backoff *= 2
			}
			continue
		}
		backoff = 200 * time.Millisecond

		if err := d.handshake(conn); err != nil {
			_ = conn.Close()
			continue
		}

		d.serveConn(ctx, conn)
		d.dropConnection(conn)
	}
}

// handshake reads the widget's hello envelope then sends ready, mirroring
// the legacy widget-side flow. After ready the connection is considered
// usable for outbound prompts.
func (d *DialEmitter) handshake(conn net.Conn) error {
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	defer conn.SetReadDeadline(time.Time{})
	r := bufio.NewReader(conn)
	line, err := r.ReadBytes('\n')
	if err != nil {
		return fmt.Errorf("read hello: %w", err)
	}
	var hello Envelope
	if err := json.Unmarshal(line, &hello); err != nil {
		return fmt.Errorf("decode hello: %w", err)
	}
	if hello.Kind != EnvelopeHello {
		return fmt.Errorf("expected hello, got %s", hello.Kind)
	}
	enc := json.NewEncoder(conn)
	if err := encodeWithDeadline(conn, enc, Envelope{Kind: EnvelopeReady}); err != nil {
		return fmt.Errorf("write ready: %w", err)
	}
	d.mu.Lock()
	d.conn = conn
	d.enc = enc
	d.ready = true
	d.mu.Unlock()
	return nil
}

// serveConn reads decision envelopes from conn and forwards them to the
// local GateService. Returns when the connection drops.
func (d *DialEmitter) serveConn(ctx context.Context, conn net.Conn) {
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 4096), 64*1024)
	doneCh := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.Close()
		case <-doneCh:
		}
	}()
	defer close(doneCh)

	for scanner.Scan() {
		var env Envelope
		if err := json.Unmarshal(scanner.Bytes(), &env); err != nil {
			continue
		}
		if env.Kind != EnvelopeRespond || env.Nonce == "" {
			continue
		}
		dec := mcp.DecisionCancelled
		switch env.Decision {
		case "approved":
			dec = mcp.DecisionApproved
		case "cancelled":
			dec = mcp.DecisionCancelled
		case "timeout":
			dec = mcp.DecisionTimeout
		}
		d.gate.Respond(env.Nonce, dec)
	}
}

func (d *DialEmitter) dropConnection(conn net.Conn) {
	d.mu.Lock()
	if d.conn == conn {
		d.conn = nil
		d.enc = nil
		d.ready = false
	}
	d.mu.Unlock()
	_ = conn.Close()
}

func encodeWithDeadline(conn net.Conn, enc *json.Encoder, env Envelope) error {
	_ = conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
	defer conn.SetWriteDeadline(time.Time{})
	return enc.Encode(env)
}
