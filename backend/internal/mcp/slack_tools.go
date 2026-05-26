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
	g.addTool(srv, "cb_slack_list_channels",
		"List Slack channels visible to the active Claude Bar account's Slack token. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("types", mcpgo.Description("Comma-separated channel types: public_channel, private_channel, mpim, im. Default: public_channel,private_channel.")),
			mcpgo.WithNumber("limit", mcpgo.Description("Max channels to return (1-200). Default 100.")),
		},
		g.slackListChannels,
	)

	g.addTool(srv, "cb_slack_search_messages",
		"Search Slack messages with the given query. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("query", mcpgo.Required(), mcpgo.Description("Slack search query, same syntax as Slack search.")),
			mcpgo.WithNumber("count", mcpgo.Description("Max results (1-100). Default 20.")),
		},
		g.slackSearchMessages,
	)

	g.addTool(srv, "cb_slack_get_thread",
		"Get all replies in a Slack thread. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("channel", mcpgo.Required(), mcpgo.Description("Channel ID, e.g. C0123ABCD.")),
			mcpgo.WithString("thread_ts", mcpgo.Required(), mcpgo.Description("Parent message ts, e.g. 1700000000.123456.")),
		},
		g.slackGetThread,
	)

	g.addTool(srv, "cb_slack_get_channel_history",
		"Fetch recent messages from a Slack channel. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("channel", mcpgo.Required(), mcpgo.Description("Channel ID, e.g. C0123ABCD.")),
			mcpgo.WithNumber("limit", mcpgo.Description("Max messages (1-200). Default 50.")),
			mcpgo.WithString("oldest", mcpgo.Description("Only return messages newer than this ts (e.g. 1700000000.000000).")),
			mcpgo.WithString("latest", mcpgo.Description("Only return messages older than this ts.")),
		},
		g.slackGetChannelHistory,
	)

	g.addTool(srv, "cb_slack_list_users",
		"List Slack workspace users so the agent can resolve U0123ABC IDs to names. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithNumber("limit", mcpgo.Description("Max users per page (1-200). Default 100.")),
			mcpgo.WithString("cursor", mcpgo.Description("Pagination cursor returned by a previous call.")),
			mcpgo.WithBoolean("include_deleted", mcpgo.Description("Include deactivated users. Default false.")),
		},
		g.slackListUsers,
	)

	g.addTool(srv, "cb_slack_get_user",
		"Look up a single Slack user by ID. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("user", mcpgo.Required(), mcpgo.Description("Slack user ID, e.g. U0123ABCD.")),
		},
		g.slackGetUser,
	)

	g.addTool(srv, "cb_slack_get_permalink",
		"Get a shareable URL for a Slack message. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("channel", mcpgo.Required(), mcpgo.Description("Channel ID, e.g. C0123ABCD.")),
			mcpgo.WithString("message_ts", mcpgo.Required(), mcpgo.Description("Message ts, e.g. 1700000000.123456.")),
		},
		g.slackGetPermalink,
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

func (g *Gateway) slackGetChannelHistory(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceSlack)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	channel, err := req.RequireString("channel")
	if err != nil {
		return toolErrorf("channel is required"), nil
	}
	params := url.Values{}
	params.Set("channel", channel)
	params.Set("limit", strconv.Itoa(clampInt(req.GetInt("limit", 50), 1, 200)))
	if v := req.GetString("oldest", ""); v != "" {
		params.Set("oldest", v)
	}
	if v := req.GetString("latest", ""); v != "" {
		params.Set("latest", v)
	}

	var resp struct {
		slackResponse
		Messages []map[string]any `json:"messages"`
		HasMore  bool             `json:"has_more"`
	}
	if err := g.slackCall(ctx, cc.Payload, "conversations.history", params, &resp); err != nil {
		return toolErrorf("slack history: %v", err), nil
	}
	return jsonResult(map[string]any{"messages": resp.Messages, "has_more": resp.HasMore})
}

func (g *Gateway) slackListUsers(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceSlack)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	params := url.Values{}
	params.Set("limit", strconv.Itoa(clampInt(req.GetInt("limit", 100), 1, 200)))
	if v := req.GetString("cursor", ""); v != "" {
		params.Set("cursor", v)
	}
	includeDeleted := req.GetBool("include_deleted", false)

	var resp struct {
		slackResponse
		Members          []map[string]any `json:"members"`
		ResponseMetadata struct {
			NextCursor string `json:"next_cursor"`
		} `json:"response_metadata"`
	}
	if err := g.slackCall(ctx, cc.Payload, "users.list", params, &resp); err != nil {
		return toolErrorf("slack list users: %v", err), nil
	}
	members := resp.Members
	if !includeDeleted {
		filtered := members[:0]
		for _, m := range members {
			if deleted, _ := m["deleted"].(bool); !deleted {
				filtered = append(filtered, m)
			}
		}
		members = filtered
	}
	return jsonResult(map[string]any{"members": members, "next_cursor": resp.ResponseMetadata.NextCursor})
}

func (g *Gateway) slackGetUser(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceSlack)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	user, err := req.RequireString("user")
	if err != nil {
		return toolErrorf("user is required"), nil
	}
	params := url.Values{}
	params.Set("user", user)

	var resp struct {
		slackResponse
		User map[string]any `json:"user"`
	}
	if err := g.slackCall(ctx, cc.Payload, "users.info", params, &resp); err != nil {
		return toolErrorf("slack user info: %v", err), nil
	}
	return jsonResult(resp.User)
}

func (g *Gateway) slackGetPermalink(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceSlack)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	channel, err := req.RequireString("channel")
	if err != nil {
		return toolErrorf("channel is required"), nil
	}
	messageTS, err := req.RequireString("message_ts")
	if err != nil {
		return toolErrorf("message_ts is required"), nil
	}
	params := url.Values{}
	params.Set("channel", channel)
	params.Set("message_ts", messageTS)

	var resp struct {
		slackResponse
		Permalink string `json:"permalink"`
		Channel   string `json:"channel"`
	}
	if err := g.slackCall(ctx, cc.Payload, "chat.getPermalink", params, &resp); err != nil {
		return toolErrorf("slack permalink: %v", err), nil
	}
	return jsonResult(map[string]any{"permalink": resp.Permalink, "channel": resp.Channel})
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
