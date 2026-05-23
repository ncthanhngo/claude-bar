package mcp

import (
	"context"
	"net/http"
	"time"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/bwcli"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// Gateway wires the MCP server to the Claude Bar backend.
//
// All tools resolve the active Claude Bar account per call. Switching
// accounts in the menu bar changes which connector profile the next tool
// call uses, with no restart of Claude Code required (tool names stay
// stable across switches).
type Gateway struct {
	Resolver  *Resolver
	HTTP      *http.Client
	UserAgent string
	Version   string

	// Gate coordinates write-tool approval. nil means no widget is wired —
	// every write blocks and returns user_cancelled (safe default for CLI
	// invocations and tests).
	Gate *GateService

	// Audit is the append-only event sink. nil means audit logging is
	// disabled (tests, dry-run); writers tolerate nil.
	Audit *AuditWriter

	// SSHStore is the registry of tracked SSH hosts. nil disables SSH tools.
	SSHStore SSHHostStore

	// SSHRunner executes ssh against tracked hosts. Defaults to a real
	// ssh-binary runner when SSHStore is set.
	SSHRunner SSHExec

	// GitLabInstances is the registry of self-hosted GitLab instances. nil
	// disables GitLab tools.
	GitLabInstances *GitLabInstanceStore

	// BWSession is the Bitwarden in-memory session holder. nil disables BW.
	BWSession *BitwardenSession

	// BWRunner runs the `bw` CLI. Defaults to ExecRunner when BWSession is set.
	BWRunner bwcli.Runner
}

// New builds a Gateway with sane defaults.
func New(registry port.RegistryStore, secrets port.MCPSecretStore, version string) *Gateway {
	return &Gateway{
		Resolver: &Resolver{Registry: registry, Secrets: secrets},
		HTTP: &http.Client{
			Timeout: 20 * time.Second,
		},
		UserAgent: "claude-bar-mcp/" + version,
		Version:   version,
	}
}

// BuildServer registers every connector's tools and returns the MCP server.
func (g *Gateway) BuildServer() *server.MCPServer {
	srv := server.NewMCPServer(
		"claude-bar-mcp",
		g.Version,
		server.WithToolCapabilities(true),
	)
	g.registerSlackTools(srv)
	g.registerClickUpTools(srv)
	g.registerClickUpWriteTools(srv)
	g.registerClickUpCaptureTool(srv)
	g.registerGDriveTools(srv)
	g.registerGCalTools(srv)
	g.registerGmailTools(srv)
	g.registerGitHubTools(srv)
	g.registerGitHubWriteTools(srv)
	g.registerSSHTools(srv)
	g.registerGitLabTools(srv)
	g.registerBitwardenTools(srv)
	return srv
}

// ServeStdio runs the MCP server over stdio until the client disconnects.
func (g *Gateway) ServeStdio(ctx context.Context) error {
	_ = ctx // mcp-go ServeStdio is blocking and manages its own lifecycle.
	return server.ServeStdio(g.BuildServer())
}

// addTool is a tiny shim so connector files can build tools concisely.
func addTool(srv *server.MCPServer, name, description string, opts []mcpgo.ToolOption, handler server.ToolHandlerFunc) {
	full := append([]mcpgo.ToolOption{mcpgo.WithDescription(description)}, opts...)
	srv.AddTool(mcpgo.NewTool(name, full...), handler)
}
