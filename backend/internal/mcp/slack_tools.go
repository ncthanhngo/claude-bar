package mcp

import (
	"context"
	"encoding/json"
	"net/url"
	"strconv"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

func (g *Gateway) registerSlackTools(srv *server.MCPServer) {
	addTool(srv, "cb_slack_list_channels",
		"List Slack channels visible to the active Claude Bar account's Slack token. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("types", mcpgo.Description("Comma-separated channel types: public_channel, private_channel, mpim, im. Default: public_channel,private_channel.")),
			mcpgo.WithNumber("limit", mcpgo.Description("Max channels to return (1-200). Default 100.")),
		},
		g.slackListChannels,
	)

	addTool(srv, "cb_slack_search_messages",
		"Search Slack messages with the given query. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("query", mcpgo.Required(), mcpgo.Description("Slack search query, same syntax as Slack search.")),
			mcpgo.WithNumber("count", mcpgo.Description("Max results (1-100). Default 20.")),
		},
		g.slackSearchMessages,
	)

	addTool(srv, "cb_slack_get_thread",
		"Get all replies in a Slack thread. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("channel", mcpgo.Required(), mcpgo.Description("Channel ID, e.g. C0123ABCD.")),
			mcpgo.WithString("thread_ts", mcpgo.Required(), mcpgo.Description("Parent message ts, e.g. 1700000000.123456.")),
		},
		g.slackGetThread,
	)
}

func (g *Gateway) slackListChannels(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceSlack)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	params := url.Values{}
	types := req.GetString("types", "public_channel,private_channel")
	params.Set("types", types)
	params.Set("limit", strconv.Itoa(clampInt(req.GetInt("limit", 100), 1, 200)))
	params.Set("exclude_archived", "true")

	var resp struct {
		slackResponse
		Channels []map[string]any `json:"channels"`
	}
	if err := g.slackCall(ctx, cc.Payload, "conversations.list", params, &resp); err != nil {
		return toolErrorf("slack list channels: %v", err), nil
	}
	return jsonResult(resp.Channels)
}

func (g *Gateway) slackSearchMessages(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceSlack)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	query, err := req.RequireString("query")
	if err != nil {
		return toolErrorf("query is required"), nil
	}
	params := url.Values{}
	params.Set("query", query)
	params.Set("count", strconv.Itoa(clampInt(req.GetInt("count", 20), 1, 100)))

	var resp struct {
		slackResponse
		Messages struct {
			Matches []map[string]any `json:"matches"`
			Total   int              `json:"total"`
		} `json:"messages"`
	}
	if err := g.slackCall(ctx, cc.Payload, "search.messages", params, &resp); err != nil {
		return toolErrorf("slack search: %v", err), nil
	}
	return jsonResult(map[string]any{"matches": resp.Messages.Matches, "total": resp.Messages.Total})
}

func (g *Gateway) slackGetThread(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceSlack)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	channel, err := req.RequireString("channel")
	if err != nil {
		return toolErrorf("channel is required"), nil
	}
	threadTS, err := req.RequireString("thread_ts")
	if err != nil {
		return toolErrorf("thread_ts is required"), nil
	}
	params := url.Values{}
	params.Set("channel", channel)
	params.Set("ts", threadTS)

	var resp struct {
		slackResponse
		Messages []map[string]any `json:"messages"`
	}
	if err := g.slackCall(ctx, cc.Payload, "conversations.replies", params, &resp); err != nil {
		return toolErrorf("slack thread: %v", err), nil
	}
	return jsonResult(resp.Messages)
}

func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func jsonResult(v any) (*mcpgo.CallToolResult, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return toolErrorf("marshal: %v", err), nil
	}
	return mcpgo.NewToolResultText(string(b)), nil
}
