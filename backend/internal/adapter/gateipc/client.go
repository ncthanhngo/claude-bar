package gateipc

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"time"
)

// ProxyReader bridges a UDS connection to a process-level stdio stream. It is
// used by `csw gate proxy`: the widget spawns this subprocess, reads
// newline-delimited prompt JSON from stdout, and writes decision JSON to
// stdin. The subprocess simply mirrors traffic to/from the UDS.
type ProxyReader struct {
	SocketPath string
}

// Run streams prompts from the UDS to stdout and forwards stdin lines to the
// UDS. Returns when stdin closes, stdout fails, or ctx is cancelled.
// Reconnects with exponential backoff when the MCP server socket is not up yet
// or when the MCP subprocess restarts.
func (p ProxyReader) Run(ctx context.Context, stdin io.Reader, stdout io.Writer) error {
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	stdinLines := make(chan []byte)
	stdinErr := make(chan error, 1)
	go func() {
		defer close(stdinLines)
		r := bufio.NewScanner(stdin)
		r.Buffer(make([]byte, 4096), 64*1024)
		for r.Scan() {
			line := append([]byte(nil), r.Bytes()...)
			select {
			case stdinLines <- line:
			case <-runCtx.Done():
				return
			}
		}
		stdinErr <- r.Err()
		cancel()
	}()

	for {
		conn, err := dialWithRetry(runCtx, p.SocketPath, 0)
		if err != nil {
			select {
			case stdinScanErr := <-stdinErr:
				return stdinScanErr
			default:
			}
			return err
		}

		connDone := make(chan proxyConnEvent, 1)
		go func(conn net.Conn) {
			r := bufio.NewScanner(conn)
			r.Buffer(make([]byte, 4096), 64*1024)
			for r.Scan() {
				if _, err := stdout.Write(append(r.Bytes(), '\n')); err != nil {
					connDone <- proxyConnEvent{err: err, stdout: true}
					return
				}
			}
			connDone <- proxyConnEvent{err: r.Err()}
		}(conn)

		reconnect := false
		for !reconnect {
			select {
			case <-runCtx.Done():
				_ = conn.Close()
				select {
				case stdinScanErr := <-stdinErr:
					return stdinScanErr
				default:
				}
				return ctx.Err()
			case err := <-stdinErr:
				_ = conn.Close()
				return err
			case line, ok := <-stdinLines:
				if !ok {
					_ = conn.Close()
					return nil
				}
				if err := writeLine(conn, line); err != nil {
					_ = conn.Close()
					reconnect = true
				}
			case ev := <-connDone:
				_ = conn.Close()
				if ev.stdout && ev.err != nil {
					return ev.err
				}
				reconnect = true
			}
		}
	}
}

type proxyConnEvent struct {
	err    error
	stdout bool
}

func dialWithRetry(ctx context.Context, path string, timeout time.Duration) (net.Conn, error) {
	var deadline time.Time
	if timeout > 0 {
		deadline = time.Now().Add(timeout)
	}
	backoff := 100 * time.Millisecond
	for {
		conn, err := net.Dial("unix", path)
		if err == nil {
			return conn, nil
		}
		if !deadline.IsZero() && time.Now().After(deadline) {
			return nil, fmt.Errorf("gate uds dial: %w", err)
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(backoff):
		}
		if backoff < 2*time.Second {
			backoff *= 2
		}
	}
}

func writeLine(conn net.Conn, line []byte) error {
	_ = conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
	defer conn.SetWriteDeadline(time.Time{})
	_, err := conn.Write(append(append([]byte(nil), line...), '\n'))
	return err
}

// SendDecision is a one-shot helper: connects, sends a single respond
// envelope, closes. Used by `csw gate respond` for users who prefer separate
// listen+respond commands. The proxy command uses bidirectional streaming
// instead and never calls this.
func SendDecision(ctx context.Context, socketPath, nonce, decision string) error {
	conn, err := dialWithRetry(ctx, socketPath, 5*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	env := Envelope{Kind: EnvelopeRespond, Nonce: nonce, Decision: decision}
	b, err := json.Marshal(env)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	_, err = conn.Write(b)
	return err
}
