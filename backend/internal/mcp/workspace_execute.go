package mcp

import (
	"context"
	"fmt"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// WorkspaceAction is one approved action from the Daily Workspace feed. The
// user has already confirmed it in the widget's confirm sheet, so this path
// deliberately bypasses the LLM write gate (runThroughGate, which fails closed
// in CLI context anyway) and calls the provider HTTP helpers directly.
type WorkspaceAction struct {
	Kind string            `json:"kind"` // mention|dm|task_due (executable subset)
	Text string            `json:"text"`
	Meta map[string]string `json:"meta"`
}

// WorkspaceExecuteResult reports the outcome back to the widget.
type WorkspaceExecuteResult struct {
	OK     bool   `json:"ok"`
	Detail string `json:"detail"`
}

// WorkspaceExecute routes an approved action to the matching provider write.
// Only Slack replies/posts and ClickUp comments are executable; email and
// meeting signals are open-only (no send surface) and return an error.
func (g *Gateway) WorkspaceExecute(ctx context.Context, a WorkspaceAction) (*WorkspaceExecuteResult, error) {
	if strings.TrimSpace(a.Text) == "" {
		return nil, fmt.Errorf("text is required")
	}
	switch a.Kind {
	case "mention", "dm":
		return g.executeSlackReply(ctx, a)
	case "task_due":
		return g.executeClickUpComment(ctx, a)
	default:
		return nil, fmt.Errorf("kind %q is not executable (open it instead)", a.Kind)
	}
}

func (g *Gateway) executeSlackReply(ctx context.Context, a WorkspaceAction) (*WorkspaceExecuteResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceSlack)
	if err != nil {
		return nil, err
	}
	channel := a.Meta["channelId"]
	if channel == "" {
		return nil, fmt.Errorf("channelId missing")
	}
	payload := map[string]any{"channel": channel, "text": a.Text}
	// Reply inside the thread when one exists, else post to the channel/DM.
	if ts := a.Meta["threadTs"]; ts != "" {
		payload["thread_ts"] = ts
	}
	var resp struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
		TS    string `json:"ts"`
	}
	if err := g.slackPostJSON(ctx, cc.Payload, "chat.postMessage", payload, &resp); err != nil {
		return nil, fmt.Errorf("slack post: %w", err)
	}
	if !resp.OK {
		return nil, fmt.Errorf("slack error: %s", resp.Error)
	}
	return &WorkspaceExecuteResult{OK: true, Detail: "Đã gửi reply Slack"}, nil
}

func (g *Gateway) executeClickUpComment(ctx context.Context, a WorkspaceAction) (*WorkspaceExecuteResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceClickUp)
	if err != nil {
		return nil, err
	}
	taskID := a.Meta["taskId"]
	if taskID == "" {
		return nil, fmt.Errorf("taskId missing")
	}
	_, _, err = g.clickupBodyJSON(ctx, "POST", cc.Payload, "/task/"+taskID+"/comment",
		map[string]any{"comment_text": a.Text})
	if err != nil {
		return nil, fmt.Errorf("clickup comment: %w", err)
	}
	return &WorkspaceExecuteResult{OK: true, Detail: "Đã thêm comment ClickUp"}, nil
}
