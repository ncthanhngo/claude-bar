// Package gateipc bridges every running MCP server's GateService to a single
// widget over a Unix domain socket.
//
// Direction: widget LISTENS, MCP servers DIAL. This lets N concurrent
// `csw mcp serve` processes — one per claude session, including subagents
// spawned by Claude Code's Task tool — all reach the same widget. The
// previous design had MCP servers race to bind a fixed path; only the
// race winner could deliver gate prompts to the widget, all other
// instances' prompts timed out with `user_cancelled: gate timed out`
// (issue #21).
//
// Wire protocol is unchanged from the prior direction: hello → ready →
// prompt / respond envelopes, newline-delimited JSON.
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
	EnvelopePrompt  EnvelopeKind = "prompt"
	EnvelopeRespond EnvelopeKind = "respond"
	EnvelopeHello   EnvelopeKind = "hello"
	EnvelopeReady   EnvelopeKind = "ready"
	EnvelopeBye     EnvelopeKind = "bye"
)

// Envelope is the single message shape sent in either direction.
type Envelope struct {
	Kind     EnvelopeKind    `json:"kind"`
	Prompt   *mcp.GatePrompt `json:"prompt,omitempty"`
	Nonce    string          `json:"nonce,omitempty"`
	Decision string          `json:"decision,omitempty"` // "approved" | "cancelled" | "timeout"
	Reason   string          `json:"reason,omitempty"`
}

// Server is the widget-side UDS listener. It accepts an arbitrary number of
// MCP-server clients and demultiplexes every inbound prompt to a single
// onPrompt callback. The reverse direction — decisions from the user —
// uses Respond(nonce, decision) which routes the response back to the
// connection that originated that nonce.
type Server struct {
	path     string
	onPrompt func(mcp.GatePrompt)

	mu          sync.Mutex
	listener    net.Listener
	conns       map[net.Conn]struct{}
	nonceToConn map[string]net.Conn
	closeOnce   sync.Once
}

// NewServer binds nothing yet; call Start. onPrompt is invoked for every
// inbound prompt from any client. Implementations forward the prompt to
// the widget UI (typically by writing a JSON envelope to stdout).
func NewServer(path string, onPrompt func(mcp.GatePrompt)) *Server {
	return &Server{
		path:        path,
		onPrompt:    onPrompt,
		conns:       make(map[net.Conn]struct{}),
		nonceToConn: make(map[string]net.Conn),
	}
}

// Start binds the UDS and accepts client connections until ctx is
// cancelled. The socket file is removed on shutdown.
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

	go s.acceptLoop(ctx)
	go func() {
		<-ctx.Done()
		s.shutdown()
	}()
	return nil
}

// Respond routes a decision envelope back to the MCP server that
// originated the given nonce. Unknown nonces are dropped silently —
// they can happen if the originating MCP server already disconnected
// (process exit, timeout, or transport error).
func (s *Server) Respond(nonce, decision string) {
	s.mu.Lock()
	conn := s.nonceToConn[nonce]
	delete(s.nonceToConn, nonce)
	s.mu.Unlock()
	if conn == nil {
		return
	}
	env := Envelope{Kind: EnvelopeRespond, Nonce: nonce, Decision: decision}
	if err := writeEnvelope(conn, env); err != nil {
		s.dropConn(conn)
	}
}

// ActiveClientCount returns the number of MCP servers currently connected.
// For diagnostics / tests.
func (s *Server) ActiveClientCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.conns)
}

func (s *Server) acceptLoop(ctx context.Context) {
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return
			}
			time.Sleep(50 * time.Millisecond)
			continue
		}
		go s.handleClient(ctx, conn)
	}
}

func (s *Server) handleClient(ctx context.Context, conn net.Conn) {
	s.mu.Lock()
	s.conns[conn] = struct{}{}
	s.mu.Unlock()

	// Send hello. Client (csw mcp serve) replies with ready.
	if err := writeEnvelope(conn, Envelope{Kind: EnvelopeHello}); err != nil {
		s.dropConn(conn)
		return
	}

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 4096), 64*1024)
	for scanner.Scan() {
		if ctx.Err() != nil {
			break
		}
		var env Envelope
		if err := json.Unmarshal(scanner.Bytes(), &env); err != nil {
			continue
		}
		switch env.Kind {
		case EnvelopeReady:
			// Ack only — no flushing needed since prompts are pushed
			// by the MCP server, not queued by us.
		case EnvelopePrompt:
			if env.Prompt == nil || env.Prompt.Nonce == "" {
				continue
			}
			s.mu.Lock()
			s.nonceToConn[env.Prompt.Nonce] = conn
			s.mu.Unlock()
			if s.onPrompt != nil {
				s.onPrompt(*env.Prompt)
			}
		}
	}
	s.dropConn(conn)
}

func (s *Server) dropConn(conn net.Conn) {
	s.mu.Lock()
	delete(s.conns, conn)
	for nonce, c := range s.nonceToConn {
		if c == conn {
			delete(s.nonceToConn, nonce)
		}
	}
	s.mu.Unlock()
	_ = conn.Close()
}

func (s *Server) shutdown() {
	s.closeOnce.Do(func() {
		if s.listener != nil {
			_ = s.listener.Close()
		}
		s.mu.Lock()
		for c := range s.conns {
			_ = c.Close()
		}
		s.conns = make(map[net.Conn]struct{})
		s.nonceToConn = make(map[string]net.Conn)
		s.mu.Unlock()
		_ = os.Remove(s.path)
	})
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
