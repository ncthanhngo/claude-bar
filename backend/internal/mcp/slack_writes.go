package mcp

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// registerSlackWriteTools registers the gated write surface for Slack.
// Each call routes through Gateway.Gate.AwaitApproval before hitting
// Slack's chat.postMessage endpoint.
func (g *Gateway) registerSlackWriteTools(srv *server.MCPServer) {
	g.addTool(srv, "cb_slack_post_message",
		"Post a new message to a Slack channel or DM. Gated.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("channel", mcpgo.Required(), mcpgo.Description("Channel ID or DM ID (e.g. C0123ABCD or D0123ABCD).")),
			mcpgo.WithString("text", mcpgo.Required(), mcpgo.Description("Message text (Slack mrkdwn).")),
		},
		g.slackPostMessage,
	)

	g.addTool(srv, "cb_slack_reply_thread",
		"Reply inside an existing Slack thread. Gated.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("channel", mcpgo.Required(), mcpgo.Description("Channel ID hosting the thread.")),
			mcpgo.WithString("thread_ts", mcpgo.Required(), mcpgo.Description("Parent message ts, e.g. 1700000000.123456.")),
			mcpgo.WithString("text", mcpgo.Required(), mcpgo.Description("Reply text (Slack mrkdwn).")),
			mcpgo.WithBoolean("broadcast", mcpgo.Description("Also post the reply to the channel. Default false.")),
		},
		g.slackReplyThread,
	)
}

func (g *Gateway) slackPostMessage(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceSlack)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	channel, err := req.RequireString("channel")
	if err != nil {
		return toolErrorf("channel is required"), nil
	}
	text, err := req.RequireString("text")
	if err != nil || strings.TrimSpace(text) == "" {
		return toolErrorf("text is required"), nil
	}

	args := map[string]any{"channel": channel, "text": text}
	summary := fmt.Sprintf("Slack: post to %s", channel)
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_slack_post_message",
		Risk:    RiskLow,
		Origin:  OriginLLM,
		Summary: summary,
		Args:    args,
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			payload := map[string]any{"channel": channel, "text": text}
			var resp struct {
				slackResponse
				Channel string         `json:"channel"`
				TS      string         `json:"ts"`
				Message map[string]any `json:"message"`
			}
			if err := g.slackPostJSON(ctx, cc.Payload, "chat.postMessage", payload, &resp); err != nil {
				return toolErrorf("slack post: %v", err), nil
			}
			return jsonResult(map[string]any{"channel": resp.Channel, "ts": resp.TS, "message": resp.Message})
		},
	})
}

func (g *Gateway) slackReplyThread(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
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
	text, err := req.RequireString("text")
	if err != nil || strings.TrimSpace(text) == "" {
		return toolErrorf("text is required"), nil
	}
	broadcast := req.GetBool("broadcast", false)

	args := map[string]any{"channel": channel, "thread_ts": threadTS, "text": text, "broadcast": broadcast}
	summary := fmt.Sprintf("Slack: reply in %s thread %s", channel, threadTS)
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_slack_reply_thread",
		Risk:    RiskLow,
		Origin:  OriginLLM,
		Summary: summary,
		Args:    args,
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			payload := map[string]any{
				"channel":         channel,
				"thread_ts":       threadTS,
				"text":            text,
				"reply_broadcast": broadcast,
			}
			var resp struct {
				slackResponse
				Channel string         `json:"channel"`
				TS      string         `json:"ts"`
				Message map[string]any `json:"message"`
			}
			if err := g.slackPostJSON(ctx, cc.Payload, "chat.postMessage", payload, &resp); err != nil {
				return toolErrorf("slack reply: %v", err), nil
			}
			return jsonResult(map[string]any{"channel": resp.Channel, "ts": resp.TS, "message": resp.Message})
		},
	})
}
