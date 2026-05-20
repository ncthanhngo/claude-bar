package mcp

import (
	"context"
	"net/http"
	"time"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"

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
	g.registerGDriveTools(srv)
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
