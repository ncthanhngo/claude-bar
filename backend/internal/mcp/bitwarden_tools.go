package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/bwcli"
)

// Phase 9 — Bitwarden read-only MCP. Every call passes an approve-gate
// (RiskReadSensitive) so LLM-context injection cannot silently exfiltrate
// passwords. Search returns only summaries (id/name/folder/uris); Get
// strips passwords / TOTP / notes / hidden fields when reveal=false.

func (g *Gateway) registerBitwardenTools(srv *server.MCPServer) {
	if g.BWSession == nil {
		return
	}
	if g.BWRunner == nil {
		g.BWRunner = bwcli.ExecRunner{}
	}

	g.addTool(srv, "cb_bw_search_items",
		"Search the Bitwarden vault by query string. Returns summaries (no secret material). Per-call approve gate.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("query", mcpgo.Required(), mcpgo.Description("Search query (item name, folder, URI fragment).")),
		},
		g.bwSearchItems,
	)

	g.addTool(srv, "cb_bw_get_item",
		"Get one Bitwarden item by id. Pass reveal=true to include password/totp/notes/hidden fields; both reveal=false and reveal=true pass the approve gate.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("id", mcpgo.Required(), mcpgo.Description("Bitwarden item ID.")),
			mcpgo.WithBoolean("reveal", mcpgo.Description("Include secrets. Default false.")),
		},
		g.bwGetItem,
	)

	g.addTool(srv, "cb_bw_list_folders",
		"List Bitwarden vault folders (id + name). Lets the agent discover folder IDs before constraining a search. Per-call approve gate.",
		nil,
		g.bwListFolders,
	)
}

func (g *Gateway) bwSearchItems(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	query, err := req.RequireString("query")
	if err != nil || strings.TrimSpace(query) == "" {
		return toolErrorf("query is required"), nil
	}
	token, ok := g.BWSession.Token()
	if !ok {
		return toolErrorf("%s", ErrBitwardenLocked.Error()), nil
	}

	args := map[string]any{"query": query}
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_bw_search_items",
		Risk:    RiskReadSensitive,
		Origin:  OriginLLM,
		Summary: fmt.Sprintf("Bitwarden: search %q", query),
		Args:    args,
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			results, err := bwcli.Search(ctx, g.BWRunner, token, query)
			if err != nil {
				return toolErrorf("bw search: %v", err), nil
			}
			b, _ := json.Marshal(results)
			return mcpgo.NewToolResultText(string(b)), nil
		},
	})
}

func (g *Gateway) bwListFolders(ctx context.Context, _ mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	token, ok := g.BWSession.Token()
	if !ok {
		return toolErrorf("%s", ErrBitwardenLocked.Error()), nil
	}
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_bw_list_folders",
		Risk:    RiskReadSensitive,
		Origin:  OriginLLM,
		Summary: "Bitwarden: list folders",
		Args:    map[string]any{},
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			folders, err := bwcli.ListFolders(ctx, g.BWRunner, token)
			if err != nil {
				return toolErrorf("bw list folders: %v", err), nil
			}
			b, _ := json.Marshal(folders)
			return mcpgo.NewToolResultText(string(b)), nil
		},
	})
}

func (g *Gateway) bwGetItem(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	id, err := req.RequireString("id")
	if err != nil || strings.TrimSpace(id) == "" {
		return toolErrorf("id is required"), nil
	}
	reveal := req.GetBool("reveal", false)
	token, ok := g.BWSession.Token()
	if !ok {
		return toolErrorf("%s", ErrBitwardenLocked.Error()), nil
	}

	args := map[string]any{"id": id, "reveal": reveal}
	risk := RiskReadSensitive
	if reveal {
		// Reveal escalates to Destructive so the modal fires (not the chip)
		// — surfacing a password should never be a 2-tap inline approve.
		risk = RiskDestructive
	}
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_bw_get_item",
		Risk:    risk,
		Origin:  OriginLLM,
		Summary: fmt.Sprintf("Bitwarden: get item %s (reveal=%v)", id, reveal),
		Args:    args,
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			item, err := bwcli.Get(ctx, g.BWRunner, token, id, reveal)
			if err != nil {
				return toolErrorf("bw get: %v", err), nil
			}
			b, _ := json.Marshal(item)
			return mcpgo.NewToolResultText(string(b)), nil
		},
	})
}
