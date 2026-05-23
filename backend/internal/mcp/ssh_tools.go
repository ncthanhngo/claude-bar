package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"

	sshadp "github.com/soi/claude-swap-widget/backend/internal/adapter/ssh"
)

// SSHHostStore is the interface the MCP gateway needs from the SSH adapter.
// Kept tiny so the gateway doesn't pull in the full adapter test surface.
type SSHHostStore interface {
	List(ctx context.Context) ([]sshadp.TrackedHost, error)
	Get(ctx context.Context, name string) (*sshadp.TrackedHost, error)
	MarkConnected(ctx context.Context, name string, when time.Time) error
}

// SSHExec lets tests substitute a fake `ssh` runner.
type SSHExec interface {
	Exec(ctx context.Context, host sshadp.TrackedHost, cmd string, timeout time.Duration) (*sshadp.ExecResult, error)
	Tail(ctx context.Context, host sshadp.TrackedHost, path string, lines, followSeconds int) (*sshadp.ExecResult, error)
}

type realSSHExec struct{}

func (realSSHExec) Exec(ctx context.Context, host sshadp.TrackedHost, cmd string, timeout time.Duration) (*sshadp.ExecResult, error) {
	return sshadp.Exec(ctx, host, cmd, timeout)
}
func (realSSHExec) Tail(ctx context.Context, host sshadp.TrackedHost, path string, lines, followSeconds int) (*sshadp.ExecResult, error) {
	return sshadp.Tail(ctx, host, path, lines, followSeconds)
}

// registerSSHTools registers the 3 SSH tools. cb_ssh_exec is gated; the other
// two are reads with no gate (list returns tracked-host metadata only; tail
// reads remote files but cannot mutate, so it's treated as a low-risk read).
func (g *Gateway) registerSSHTools(srv *server.MCPServer) {
	if g.SSHStore == nil {
		return // SSH not wired (older build / tests)
	}
	if g.SSHRunner == nil {
		g.SSHRunner = realSSHExec{}
	}

	addTool(srv, "cb_ssh_list_hosts",
		"List SSH hosts tracked by Claude Bar (name + connection metadata). Read-only.",
		nil,
		g.sshListHosts,
	)

	addTool(srv, "cb_ssh_exec",
		"Run a command on a tracked SSH host. Gated; risk is classified server-side.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("host", mcpgo.Required(), mcpgo.Description("Tracked host name (matches ~/.ssh/config Host stanza).")),
			mcpgo.WithString("cmd", mcpgo.Required(), mcpgo.Description("Command to run remotely (single argv element; no shell parsing).")),
			mcpgo.WithNumber("timeout_seconds", mcpgo.Description("Wall-clock cap. Default 30, max 300.")),
		},
		g.sshExec,
	)

	addTool(srv, "cb_ssh_tail",
		"Tail a remote file with an optional bounded follow window. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("host", mcpgo.Required(), mcpgo.Description("Tracked host name.")),
			mcpgo.WithString("path", mcpgo.Required(), mcpgo.Description("Remote file path.")),
			mcpgo.WithNumber("lines", mcpgo.Description("How many lines from the end. 1–5000. Default 100.")),
			mcpgo.WithNumber("follow_seconds", mcpgo.Description("Follow window. 0–60. Default 0 (no follow).")),
		},
		g.sshTail,
	)
}

func (g *Gateway) sshListHosts(ctx context.Context, _ mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	hosts, err := g.SSHStore.List(ctx)
	if err != nil {
		return toolErrorf("ssh list: %v", err), nil
	}
	out := make([]map[string]any, 0, len(hosts))
	for _, h := range hosts {
		out = append(out, map[string]any{
			"name":          h.Name,
			"hostName":      h.HostName,
			"port":          h.Port,
			"user":          h.User,
			"lastConnected": h.LastConnected,
		})
	}
	return jsonResult(out)
}

func (g *Gateway) sshExec(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	hostName, err := req.RequireString("host")
	if err != nil {
		return toolErrorf("host is required"), nil
	}
	cmd, err := req.RequireString("cmd")
	if err != nil || strings.TrimSpace(cmd) == "" {
		return toolErrorf("cmd is required"), nil
	}
	timeoutSec := req.GetInt("timeout_seconds", 30)
	if timeoutSec < 1 {
		timeoutSec = 30
	}
	if timeoutSec > 300 {
		timeoutSec = 300
	}

	host, err := g.SSHStore.Get(ctx, hostName)
	if err != nil {
		return toolErrorf("ssh: %v", err), nil
	}

	// Server-side risk classification: layered defence (metachar scan +
	// allowlist + table + sudo bump). LLM cannot downgrade.
	risk := mapSSHRisk(sshadp.ClassifyCmd(cmd))

	args := map[string]any{"host": hostName, "cmd": cmd, "timeout_seconds": timeoutSec}
	summary := fmt.Sprintf("SSH exec on %s: %s", hostName, cmd)

	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_ssh_exec",
		Risk:    risk,
		Origin:  OriginLLM,
		Summary: summary,
		Args:    args,
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			res, err := g.SSHRunner.Exec(ctx, *host, cmd, time.Duration(timeoutSec)*time.Second)
			if err != nil {
				return toolErrorf("ssh exec: %v", err), nil
			}
			_ = g.SSHStore.MarkConnected(ctx, hostName, time.Now().UTC())
			b, _ := json.Marshal(res)
			return mcpgo.NewToolResultText(string(b)), nil
		},
	})
}

func (g *Gateway) sshTail(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	hostName, err := req.RequireString("host")
	if err != nil {
		return toolErrorf("host is required"), nil
	}
	path, err := req.RequireString("path")
	if err != nil {
		return toolErrorf("path is required"), nil
	}
	lines := req.GetInt("lines", 100)
	follow := req.GetInt("follow_seconds", 0)

	host, err := g.SSHStore.Get(ctx, hostName)
	if err != nil {
		return toolErrorf("ssh: %v", err), nil
	}
	res, err := g.SSHRunner.Tail(ctx, *host, path, lines, follow)
	if err != nil {
		return toolErrorf("ssh tail: %v", err), nil
	}
	b, _ := json.Marshal(res)
	return mcpgo.NewToolResultText(string(b)), nil
}

func mapSSHRisk(r sshadp.Risk) Risk {
	switch r {
	case sshadp.RiskLow:
		return RiskLow
	case sshadp.RiskMedium:
		return RiskMedium
	default:
		return RiskDestructive
	}
}
