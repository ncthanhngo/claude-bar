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
// UDS. Returns when either side EOFs or ctx is cancelled. Reconnects with
// expontential backoff if the server isn't up yet.
func (p ProxyReader) Run(ctx context.Context, stdin io.Reader, stdout io.Writer) error {
	conn, err := dialWithRetry(ctx, p.SocketPath, 30*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()

	errCh := make(chan error, 2)

	// UDS → stdout
	go func() {
		r := bufio.NewScanner(conn)
		r.Buffer(make([]byte, 4096), 64*1024)
		for r.Scan() {
			if _, err := stdout.Write(append(r.Bytes(), '\n')); err != nil {
				errCh <- err
				return
			}
		}
		errCh <- r.Err()
	}()

	// stdin → UDS
	go func() {
		r := bufio.NewScanner(stdin)
		r.Buffer(make([]byte, 4096), 64*1024)
		for r.Scan() {
			line := append(r.Bytes(), '\n')
			if _, err := conn.Write(line); err != nil {
				errCh <- err
				return
			}
		}
		errCh <- r.Err()
	}()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case err := <-errCh:
		return err
	}
}

func dialWithRetry(ctx context.Context, path string, timeout time.Duration) (net.Conn, error) {
	deadline := time.Now().Add(timeout)
	backoff := 100 * time.Millisecond
	for {
		conn, err := net.Dial("unix", path)
		if err == nil {
			return conn, nil
		}
		if time.Now().After(deadline) {
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
