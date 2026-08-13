package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/mcp"
	"github.com/soi/claude-swap-widget/backend/internal/usecase"
	"github.com/soi/claude-swap-widget/backend/internal/usecase/briefing"
)

// runWorkspace dispatches `csw workspace <feed>`.
//
// The Workspace feed is the live, pollable surface behind the Daily "Workspace"
// tab: it reuses the briefing orchestrator's MCP fan-out but skips Claude,
// applying rule-based BuildSignals so the widget can poll it every few minutes
// without cost or latency.
func runWorkspace(ctx context.Context, svc *usecase.Service, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw workspace <feed> ...")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "feed":
		return runWorkspaceFeed(ctx, svc, rest)
	case "draft":
		return runWorkspaceDraft(ctx, rest)
	case "execute":
		return runWorkspaceExecute(ctx, svc, rest)
	default:
		return fmt.Errorf("unknown workspace subcommand: %s", sub)
	}
}

// runWorkspaceDraft reads a DraftInput JSON from stdin and emits a Draft.
// No MCP / account needed — the draft comes from the signal context via the
// local `claude` CLI (active account credentials).
func runWorkspaceDraft(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("draft", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	var in briefing.DraftInput
	if err := decodeStdin(&in); err != nil {
		return fmt.Errorf("decode draft input: %w", err)
	}
	runner, err := briefing.DefaultClaudeRunner()
	if err != nil {
		return err
	}
	d, err := briefing.DraftAction(ctx, runner, in)
	if err != nil {
		return err
	}
	return emit(*asJSON, d)
}

// runWorkspaceExecute reads a WorkspaceAction JSON from stdin and performs the
// approved write. The widget's confirm sheet is the human approval step.
func runWorkspaceExecute(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("execute", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	var action mcp.WorkspaceAction
	if err := decodeStdin(&action); err != nil {
		return fmt.Errorf("decode action: %w", err)
	}

	res, err := svc.ListAccounts(ctx)
	if err != nil {
		return fmt.Errorf("active account: %w", err)
	}
	if res.ActiveAccountNumber == 0 {
		return errors.New("no active Claude Bar account")
	}

	gateway := mcp.New(svc.Registry, svc.MCPSecrets, cswVersion)
	out, err := gateway.WorkspaceExecute(ctx, action)
	if err != nil {
		return err
	}
	return emit(*asJSON, out)
}

func decodeStdin(v any) error {
	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, v)
}

func runWorkspaceFeed(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("feed", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	res, err := svc.ListAccounts(ctx)
	if err != nil {
		return fmt.Errorf("active account: %w", err)
	}
	if res.ActiveAccountNumber == 0 {
		return errors.New("no active Claude Bar account")
	}

	gateway := mcp.New(svc.Registry, svc.MCPSecrets, cswVersion)
	orch := briefing.NewOrchestrator(gateway)

	now := time.Now()
	raw := orch.Fetch(ctx, res.ActiveAccountNumber)
	feed := &briefing.WorkspaceFeed{
		SchemaVersion: briefing.SchemaVersion,
		GeneratedAt:   now.UTC(),
		Signals:       briefing.BuildSignals(raw, now),
		SourcesHealth: raw.Health,
	}
	return emit(*asJSON, feed)
}
