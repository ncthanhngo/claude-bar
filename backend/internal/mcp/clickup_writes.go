package mcp

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// registerClickUpWriteTools registers the 4 write-capable ClickUp tools.
// All gate-protected. No destructive writes (delete is intentionally out of
// scope for v1 per phase-08 plan).
func (g *Gateway) registerClickUpWriteTools(srv *server.MCPServer) {
	addTool(srv, "cb_clickup_create_task",
		"Create a ClickUp task in a list. Gated.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("list_id", mcpgo.Required(), mcpgo.Description("List ID to create the task in.")),
			mcpgo.WithString("name", mcpgo.Required(), mcpgo.Description("Task title.")),
			mcpgo.WithString("description", mcpgo.Description("Markdown description.")),
			mcpgo.WithString("priority", mcpgo.Description("urgent | high | normal | low.")),
			mcpgo.WithString("due", mcpgo.Description("Due date (RFC3339).")),
		},
		g.clickupCreateTask,
	)

	addTool(srv, "cb_clickup_update_task_status",
		"Update a ClickUp task's status. Gated (Medium risk for completed/archived).",
		[]mcpgo.ToolOption{
			mcpgo.WithString("task_id", mcpgo.Required(), mcpgo.Description("Task ID.")),
			mcpgo.WithString("status", mcpgo.Required(), mcpgo.Description("New status name.")),
		},
		g.clickupUpdateTaskStatus,
	)

	addTool(srv, "cb_clickup_add_comment",
		"Add a comment to a ClickUp task. Gated.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("task_id", mcpgo.Required(), mcpgo.Description("Task ID.")),
			mcpgo.WithString("body", mcpgo.Required(), mcpgo.Description("Comment body.")),
		},
		g.clickupAddComment,
	)

	addTool(srv, "cb_clickup_assign",
		"Add or remove assignees on a ClickUp task. Gated.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("task_id", mcpgo.Required(), mcpgo.Description("Task ID.")),
			mcpgo.WithString("add", mcpgo.Description("Comma-separated assignee user IDs to add.")),
			mcpgo.WithString("remove", mcpgo.Description("Comma-separated assignee user IDs to remove.")),
		},
		g.clickupAssign,
	)
}

var priorityCodes = map[string]int{
	"urgent": 1,
	"high":   2,
	"normal": 3,
	"low":    4,
}

func (g *Gateway) clickupCreateTask(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceClickUp)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	listID, err := req.RequireString("list_id")
	if err != nil {
		return toolErrorf("list_id is required"), nil
	}
	name, err := req.RequireString("name")
	if err != nil || strings.TrimSpace(name) == "" {
		return toolErrorf("name is required"), nil
	}
	description := req.GetString("description", "")
	priority := strings.ToLower(strings.TrimSpace(req.GetString("priority", "")))
	if priority != "" {
		if _, ok := priorityCodes[priority]; !ok {
			return toolErrorf("priority must be urgent | high | normal | low"), nil
		}
	}
	due := strings.TrimSpace(req.GetString("due", ""))

	args := map[string]any{"list_id": listID, "name": name}
	if description != "" {
		args["description"] = description
	}
	if priority != "" {
		args["priority"] = priority
	}
	if due != "" {
		args["due"] = due
	}
	summary := fmt.Sprintf("ClickUp: create task %q in list %s", name, listID)
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_clickup_create_task",
		Risk:    RiskLow,
		Origin:  OriginLLM,
		Summary: summary,
		Args:    args,
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			payload := map[string]any{"name": name}
			if description != "" {
				payload["description"] = description
			}
			if code, ok := priorityCodes[priority]; ok {
				payload["priority"] = code
			}
			if due != "" {
				payload["due_date_string"] = due
			}
			body, _, err := g.clickupBodyJSON(ctx, http.MethodPost, cc.Payload, "/list/"+listID+"/task", payload)
			if err != nil {
				return toolErrorf("clickup create task: %v", err), nil
			}
			var out map[string]any
			if err := json.Unmarshal(body, &out); err != nil {
				return toolErrorf("clickup decode: %v", err), nil
			}
			return jsonResult(out)
		},
	})
}

func (g *Gateway) clickupUpdateTaskStatus(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceClickUp)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	taskID, err := req.RequireString("task_id")
	if err != nil {
		return toolErrorf("task_id is required"), nil
	}
	status, err := req.RequireString("status")
	if err != nil || strings.TrimSpace(status) == "" {
		return toolErrorf("status is required"), nil
	}

	risk := RiskLow
	switch strings.ToLower(status) {
	case "completed", "complete", "archived", "done", "closed":
		risk = RiskMedium
	}

	args := map[string]any{"task_id": taskID, "status": status}
	summary := fmt.Sprintf("ClickUp: set task %s status → %s", taskID, status)
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_clickup_update_task_status",
		Risk:    risk,
		Origin:  OriginLLM,
		Summary: summary,
		Args:    args,
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			body, _, err := g.clickupBodyJSON(ctx, http.MethodPut, cc.Payload, "/task/"+taskID, map[string]any{"status": status})
			if err != nil {
				return toolErrorf("clickup update status: %v", err), nil
			}
			var out map[string]any
			if err := json.Unmarshal(body, &out); err != nil {
				return toolErrorf("clickup decode: %v", err), nil
			}
			return jsonResult(out)
		},
	})
}

func (g *Gateway) clickupAddComment(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceClickUp)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	taskID, err := req.RequireString("task_id")
	if err != nil {
		return toolErrorf("task_id is required"), nil
	}
	body, err := req.RequireString("body")
	if err != nil || strings.TrimSpace(body) == "" {
		return toolErrorf("body is required"), nil
	}

	args := map[string]any{"task_id": taskID, "body": body}
	summary := fmt.Sprintf("ClickUp: comment on task %s", taskID)
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_clickup_add_comment",
		Risk:    RiskLow,
		Origin:  OriginLLM,
		Summary: summary,
		Args:    args,
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			out, _, err := g.clickupBodyJSON(ctx, http.MethodPost, cc.Payload, "/task/"+taskID+"/comment", map[string]any{"comment_text": body})
			if err != nil {
				return toolErrorf("clickup comment: %v", err), nil
			}
			var v map[string]any
			if err := json.Unmarshal(out, &v); err != nil {
				return toolErrorf("clickup decode: %v", err), nil
			}
			return jsonResult(v)
		},
	})
}

func (g *Gateway) clickupAssign(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceClickUp)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	taskID, err := req.RequireString("task_id")
	if err != nil {
		return toolErrorf("task_id is required"), nil
	}
	add := parseCSVInts(req.GetString("add", ""))
	rem := parseCSVInts(req.GetString("remove", ""))
	if len(add) == 0 && len(rem) == 0 {
		return toolErrorf("at least one of add or remove is required"), nil
	}

	args := map[string]any{"task_id": taskID}
	if len(add) > 0 {
		args["add"] = add
	}
	if len(rem) > 0 {
		args["remove"] = rem
	}
	summary := fmt.Sprintf("ClickUp: assignees on %s +%d/-%d", taskID, len(add), len(rem))
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_clickup_assign",
		Risk:    RiskLow,
		Origin:  OriginLLM,
		Summary: summary,
		Args:    args,
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			payload := map[string]any{"assignees": map[string]any{"add": add, "rem": rem}}
			body, _, err := g.clickupBodyJSON(ctx, http.MethodPut, cc.Payload, "/task/"+taskID, payload)
			if err != nil {
				return toolErrorf("clickup assign: %v", err), nil
			}
			var v map[string]any
			if err := json.Unmarshal(body, &v); err != nil {
				return toolErrorf("clickup decode: %v", err), nil
			}
			return jsonResult(v)
		},
	})
}

func (g *Gateway) clickupBodyJSON(ctx context.Context, method, token, path string, payload any) ([]byte, int, error) {
	buf, err := json.Marshal(payload)
	if err != nil {
		return nil, 0, fmt.Errorf("encode body: %w", err)
	}
	u := clickupAPIBase + path
	req, err := http.NewRequestWithContext(ctx, method, u, bytes.NewReader(buf))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Authorization", token) // raw, no Bearer
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", g.UserAgent)

	resp, err := g.HTTP.Do(req)
	if err != nil {
		return nil, 0, fmt.Errorf("clickup http: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, resp.StatusCode, fmt.Errorf("clickup read: %w", err)
	}
	if resp.StatusCode/100 != 2 {
		return body, resp.StatusCode, fmt.Errorf("clickup http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body))))
	}
	return body, resp.StatusCode, nil
}

func parseCSVInts(s string) []int {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]int, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		n, err := strconv.Atoi(p)
		if err != nil {
			continue
		}
		out = append(out, n)
	}
	return out
}
