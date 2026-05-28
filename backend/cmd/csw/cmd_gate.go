package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/gateipc"
	"github.com/soi/claude-swap-widget/backend/internal/mcp"
)

// runGate dispatches `csw gate <proxy>`. The widget spawns `csw gate proxy`
// once as a long-lived subprocess. The proxy binds a UDS listener that every
// running `csw mcp serve` instance dials into; it then multiplexes those
// MCP-server clients onto widget stdin/stdout so the Swift code only sees a
// single newline-delimited JSON stream.
//
// Direction was flipped (widget LISTENS, MCP servers DIAL) so concurrent MCP
// instances — one per claude session, including subagents Claude Code spawns
// for skills/Task tool — can all reach the widget. The previous design only
// served whichever MCP server won the UDS bind race; subagent prompts hit
// a 60s `user_cancelled: gate timed out` (issue #21).
func runGate(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw gate <proxy> [args]")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "proxy":
		return runGateProxy(ctx, rest)
	default:
		return fmt.Errorf("unknown gate subcommand: %s", sub)
	}
}

func runGateProxy(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("gate-proxy", flag.ExitOnError)
	sock := fs.String("socket", "", "override UDS path (default: widget data dir)")
	_ = fs.Parse(args)
	path := *sock
	if path == "" {
		path = adapter.GateSocketFile()
	}

	stdout := bufio.NewWriter(os.Stdout)

	// onPrompt fires inside the server's accept goroutine; serialise writes
	// to stdout so concurrent prompts from different MCP servers don't
	// interleave on the same line.
	var writeMu = make(chan struct{}, 1)
	writeMu <- struct{}{}
	onPrompt := func(p mcp.GatePrompt) {
		env := gateipc.Envelope{Kind: gateipc.EnvelopePrompt, Prompt: &p}
		b, err := json.Marshal(env)
		if err != nil {
			return
		}
		<-writeMu
		defer func() { writeMu <- struct{}{} }()
		_, _ = stdout.Write(append(b, '\n'))
		_ = stdout.Flush()
	}

	srv := gateipc.NewServer(path, onPrompt)
	if err := srv.Start(ctx); err != nil {
		return err
	}

	// Emit a synthetic hello on stdout so the widget knows the proxy is up
	// even before any MCP server connects. Mirrors the legacy behaviour the
	// Swift GateStreamReader expects ("isConnected = true on hello").
	if b, err := json.Marshal(gateipc.Envelope{Kind: gateipc.EnvelopeHello}); err == nil {
		<-writeMu
		_, _ = stdout.Write(append(b, '\n'))
		_ = stdout.Flush()
		writeMu <- struct{}{}
	}

	// Bridge widget stdin → server.Respond. The widget speaks the same
	// respond envelope format it used in the old direction, so no Swift
	// changes are required.
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 64*1024)
	go func() {
		for scanner.Scan() {
			var env gateipc.Envelope
			if err := json.Unmarshal(scanner.Bytes(), &env); err != nil {
				continue
			}
			switch env.Kind {
			case gateipc.EnvelopeReady:
				// Widget signals it has finished its boot. Ignored — the
				// proxy itself is always ready by the time stdin reaches it.
			case gateipc.EnvelopeRespond:
				if env.Nonce == "" {
					continue
				}
				srv.Respond(env.Nonce, env.Decision)
			}
		}
	}()

	<-ctx.Done()
	return nil
}
