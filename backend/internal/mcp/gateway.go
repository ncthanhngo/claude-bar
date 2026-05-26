package mcp

import (
	"context"
	"net/http"
	"time"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/bwcli"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
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

	// disabledTools is the per-build snapshot of tools the user has
	// switched off in Settings → MCP. Populated once per spawn in
	// BuildServer from Registry.DisabledMCPTools and then consulted by
	// `addTool` to skip registration entirely. The set is a value (not a
	// pointer) so the goroutine that read the registry can publish to
	// other paths without races — BuildServer is single-threaded.
	disabledTools map[string]bool

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

// BuildServer registers every enabled connector's tools and returns the MCP
// server. Tools belonging to disabled connectors are skipped entirely so they
// never reach the client's tools/list — which keeps thousands of schema
// tokens out of every Claude Code system prompt. Toggling a connector
// requires the user to restart their Claude Code session; the widget wires
// that up automatically by SIGINT-ing running `claude` processes after the
// set-enabled call lands.
func (g *Gateway) BuildServer() *server.MCPServer {
	srv := server.NewMCPServer(
		"claude-bar-mcp",
		g.Version,
		server.WithToolCapabilities(true),
	)
	g.disabledTools = g.loadDisabledTools()
	enabled := g.enabledServices()
	if enabled[domain.MCPServiceSlack] {
		g.registerSlackTools(srv)
		g.registerSlackWriteTools(srv)
	}
	if enabled[domain.MCPServiceClickUp] {
		g.registerClickUpTools(srv)
		g.registerClickUpWriteTools(srv)
		g.registerClickUpCaptureTool(srv)
	}
	if enabled[domain.MCPServiceGDrive] {
		// One Google OAuth scope covers Drive + Calendar + Gmail, so the
		// three tool groups share a single Enabled flag.
		g.registerGDriveTools(srv)
		g.registerGCalTools(srv)
		g.registerGmailTools(srv)
	}
	if enabled[domain.MCPServiceGitHub] {
		g.registerGitHubTools(srv)
		g.registerGitHubWriteTools(srv)
	}
	if enabled[domain.MCPServiceGitLab] {
		g.registerGitLabTools(srv)
	}
	if enabled[domain.MCPServiceBitwarden] {
		g.registerBitwardenTools(srv)
	}
	// SSH has no per-connector Enabled flag in the registry — it gates on
	// SSHStore being non-nil, which is wired separately. Always register.
	g.registerSSHTools(srv)
	return srv
}

// enabledServices returns the set of connector services that should appear in
// tools/list for this gateway process. A service is enabled when EITHER the
// shared meta has Enabled=true OR any account has Enabled=true — the
// resolver picks the right one per call. If the registry load fails (e.g.
// first-run before any account exists), we degrade to "register everything"
// rather than ship an empty toolset that masks the real error.
func (g *Gateway) enabledServices() map[domain.MCPService]bool {
	out := map[domain.MCPService]bool{}
	if g.Resolver == nil || g.Resolver.Registry == nil {
		for _, svc := range domain.AllMCPServices {
			out[svc] = true
		}
		return out
	}
	reg, err := g.Resolver.Registry.Load(context.Background())
	if err != nil {
		for _, svc := range domain.AllMCPServices {
			out[svc] = true
		}
		return out
	}
	for svc, meta := range reg.SharedMCPConnectors {
		if meta != nil && meta.Enabled {
			out[svc] = true
		}
	}
	for _, acc := range reg.Accounts {
		for svc, meta := range acc.MCPConnectors {
			if meta != nil && meta.Enabled {
				out[svc] = true
			}
		}
	}
	return out
}

// ServeStdio runs the MCP server over stdio until the client disconnects.
func (g *Gateway) ServeStdio(ctx context.Context) error {
	_ = ctx // mcp-go ServeStdio is blocking and manages its own lifecycle.
	return server.ServeStdio(g.BuildServer())
}

// addTool is the tiny shim every connector file uses to register one
// tool. It now consults `g.disabledTools` first so per-tool toggles set
// in Settings → MCP take effect: a disabled tool is skipped entirely and
// never appears in tools/list, dropping its ~hundreds of bytes from
// Claude Code's system prompt as well as blocking calls.
func (g *Gateway) addTool(srv *server.MCPServer, name, description string, opts []mcpgo.ToolOption, handler server.ToolHandlerFunc) {
	if g.disabledTools[name] {
		return
	}
	full := append([]mcpgo.ToolOption{mcpgo.WithDescription(description)}, opts...)
	srv.AddTool(mcpgo.NewTool(name, full...), handler)
}

// loadDisabledTools reads the registry once per BuildServer call and
// returns a lookup-friendly set. Falls back to an empty set on load
// failure — a stale registry should never prevent Claude Code from
// reaching its tools.
func (g *Gateway) loadDisabledTools() map[string]bool {
	out := map[string]bool{}
	if g.Resolver == nil || g.Resolver.Registry == nil {
		return out
	}
	reg, err := g.Resolver.Registry.Load(context.Background())
	if err != nil || reg == nil {
		return out
	}
	for _, id := range reg.DisabledMCPTools {
		out[id] = true
	}
	return out
}
