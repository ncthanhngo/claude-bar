package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/gateipc"
)

// runGate dispatches `csw gate <proxy|respond>`. The widget spawns
// `csw gate proxy` once as a long-lived subprocess that bridges the MCP
// server's UDS to widget stdio. One-shot `csw gate respond` is a fallback for
// debugging.
func runGate(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw gate <proxy|respond> [args]")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "proxy":
		return runGateProxy(ctx, rest)
	case "respond":
		return runGateRespond(ctx, rest)
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
	pr := gateipc.ProxyReader{SocketPath: path}
	if err := pr.Run(ctx, os.Stdin, os.Stdout); err != nil {
		// ctx cancellation is the normal shutdown path — don't surface as
		// an error (the widget terminates the subprocess via SIGINT).
		if ctx.Err() != nil {
			return nil
		}
		return err
	}
	return nil
}

func runGateRespond(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("gate-respond", flag.ExitOnError)
	nonce := fs.String("nonce", "", "gate nonce to respond to")
	decision := fs.String("decision", "", "approved | cancelled")
	sock := fs.String("socket", "", "override UDS path")
	_ = fs.Parse(args)
	if *nonce == "" || *decision == "" {
		return errors.New("--nonce and --decision are required")
	}
	path := *sock
	if path == "" {
		path = adapter.GateSocketFile()
	}
	return gateipc.SendDecision(ctx, path, *nonce, *decision)
}
