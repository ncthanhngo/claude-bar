// Package gateipc bridges the MCP server's GateService to the widget over a
// Unix domain socket. The MCP server (csw mcp serve) runs as a long-lived
// subprocess of Claude Code; the widget connects via `csw gate proxy` and
// receives newline-delimited JSON gate prompts, replying with decisions on
// the same socket.
package gateipc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"sync"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/mcp"
)

// EnvelopeKind tags messages on the wire.
type EnvelopeKind string

const (
	EnvelopePrompt   EnvelopeKind = "prompt"
	EnvelopeRespond  EnvelopeKind = "respond"
	EnvelopeHello    EnvelopeKind = "hello"
	EnvelopeBye      EnvelopeKind = "bye"
)

// Envelope is the single message shape sent in either direction.
type Envelope struct {
	Kind     EnvelopeKind     `json:"kind"`
	Prompt   *mcp.GatePrompt  `json:"prompt,omitempty"`
	Nonce    string           `json:"nonce,omitempty"`
	Decision string           `json:"decision,omitempty"` // "approved" | "cancelled"
	Reason   string           `json:"reason,omitempty"`
}

// Server accepts a single widget subscriber at a time. When the widget
// disconnects, prompts are queued until it reconnects (best-effort, capped).
type Server struct {
	path string
	gate *mcp.GateService

	mu         sync.Mutex
	listener   net.Listener
	current    net.Conn // active subscriber (nil if none)
	queue      []mcp.GatePrompt
	maxQueue   int
}

// NewServer wires a UDS server on path and bridges to gate.
func NewServer(path string, gate *mcp.GateService) *Server {
	return &Server{path: path, gate: gate, maxQueue: 32}
}

// Start binds the socket, attaches itself as the gate's emitter, and serves
// connections in the background until ctx is cancelled. The socket file is
// removed on shutdown.
func (s *Server) Start(ctx context.Context) error {
	_ = os.Remove(s.path)
	l, err := net.Listen("unix", s.path)
	if err != nil {
		return fmt.Errorf("gate uds listen: %w", err)
	}
	if err := os.Chmod(s.path, 0o600); err != nil {
		_ = l.Close()
		return fmt.Errorf("gate uds perms: %w", err)
	}
	s.listener = l
	s.gate.Emitter = serverEmitter{s: s}

	go s.acceptLoop(ctx)
	go func() {
		<-ctx.Done()
		_ = l.Close()
		s.mu.Lock()
		if s.current != nil {
			_ = s.current.Close()
			s.current = nil
		}
		s.mu.Unlock()
		_ = os.Remove(s.path)
	}()
	return nil
}

func (s *Server) acceptLoop(ctx context.Context) {
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			if errors.Is(err, net.ErrClosed) {
				return
			}
			time.Sleep(50 * time.Millisecond)
			continue
		}
		go s.handleSubscriber(ctx, conn)
	}
}

func (s *Server) handleSubscriber(ctx context.Context, conn net.Conn) {
	// One subscriber at a time. Drop any prior subscriber.
	s.mu.Lock()
	if s.current != nil {
		_ = s.current.Close()
	}
	s.current = conn
	queued := append([]mcp.GatePrompt(nil), s.queue...)
	s.queue = s.queue[:0]
	s.mu.Unlock()

	// Greet + flush queue.
	enc := json.NewEncoder(conn)
	if err := enc.Encode(Envelope{Kind: EnvelopeHello}); err != nil {
		s.dropSubscriber(conn)
		return
	}
	for _, p := range queued {
		pcopy := p
		if err := enc.Encode(Envelope{Kind: EnvelopePrompt, Prompt: &pcopy}); err != nil {
			s.dropSubscriber(conn)
			return
		}
	}

	// Read decisions until conn closes.
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 4096), 64*1024)
	for scanner.Scan() {
		var env Envelope
		if err := json.Unmarshal(scanner.Bytes(), &env); err != nil {
			continue
		}
		if env.Kind != EnvelopeRespond || env.Nonce == "" {
			continue
		}
		d := mcp.DecisionCancelled
		switch env.Decision {
		case "approved":
			d = mcp.DecisionApproved
		case "cancelled":
			d = mcp.DecisionCancelled
		case "timeout":
			d = mcp.DecisionTimeout
		}
		s.gate.Respond(env.Nonce, d)
	}
	s.dropSubscriber(conn)
}

func (s *Server) dropSubscriber(conn net.Conn) {
	s.mu.Lock()
	if s.current == conn {
		s.current = nil
	}
	s.mu.Unlock()
	_ = conn.Close()
}

// emit sends a prompt to the subscriber if one is connected, otherwise queues.
func (s *Server) emit(p mcp.GatePrompt) error {
	s.mu.Lock()
	conn := s.current
	if conn == nil {
		// Cap queue: drop oldest when full.
		if len(s.queue) >= s.maxQueue {
			s.queue = s.queue[1:]
		}
		s.queue = append(s.queue, p)
		s.mu.Unlock()
		return nil
	}
	s.mu.Unlock()

	if err := writeEnvelope(conn, Envelope{Kind: EnvelopePrompt, Prompt: &p}); err != nil {
		s.dropSubscriber(conn)
		// Stash for next subscriber.
		s.mu.Lock()
		if len(s.queue) < s.maxQueue {
			s.queue = append(s.queue, p)
		}
		s.mu.Unlock()
		return nil
	}
	return nil
}

func writeEnvelope(conn net.Conn, env Envelope) error {
	_ = conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
	defer conn.SetWriteDeadline(time.Time{})
	b, err := json.Marshal(env)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	_, err = conn.Write(b)
	return err
}

type serverEmitter struct{ s *Server }

func (e serverEmitter) Emit(p mcp.GatePrompt) error { return e.s.emit(p) }
