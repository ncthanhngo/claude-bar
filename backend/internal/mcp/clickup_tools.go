package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

var clickupAPIBase = "https://api.clickup.com/api/v2"

func (g *Gateway) registerClickUpTools(srv *server.MCPServer) {
	g.addTool(srv, "cb_clickup_list_workspaces",
		"List ClickUp workspaces (teams) the personal API token has access to. Read-only.",
		nil,
		g.clickupListWorkspaces,
	)

	g.addTool(srv, "cb_clickup_list_spaces",
		"List ClickUp spaces in a workspace/team. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("workspace_id", mcpgo.Required(), mcpgo.Description("ClickUp workspace/team ID.")),
			mcpgo.WithBoolean("archived", mcpgo.Description("Include archived spaces. Default false.")),
		},
		g.clickupListSpaces,
	)

	g.addTool(srv, "cb_clickup_list_folders",
		"List ClickUp folders in a space. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("space_id", mcpgo.Required(), mcpgo.Description("ClickUp space ID.")),
			mcpgo.WithBoolean("archived", mcpgo.Description("Include archived folders. Default false.")),
		},
		g.clickupListFolders,
	)

	g.addTool(srv, "cb_clickup_list_lists",
		"List ClickUp lists in a folder or folderless space. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("folder_id", mcpgo.Description("ClickUp folder ID. Use either folder_id or space_id.")),
			mcpgo.WithString("space_id", mcpgo.Description("ClickUp space ID for folderless lists. Use either folder_id or space_id.")),
			mcpgo.WithBoolean("archived", mcpgo.Description("Include archived lists. Default false.")),
		},
		g.clickupListLists,
	)

	g.addTool(srv, "cb_clickup_list_tasks",
		"List ClickUp tasks for a list, optionally filtered by status and assignee. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("list_id", mcpgo.Required(), mcpgo.Description("ClickUp list ID.")),
			mcpgo.WithString("statuses", mcpgo.Description("Comma-separated status names to include.")),
			mcpgo.WithBoolean("include_closed", mcpgo.Description("Include closed tasks. Default false.")),
		},
		g.clickupListTasks,
	)

	g.addTool(srv, "cb_clickup_get_task",
		"Get a single ClickUp task by ID. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("task_id", mcpgo.Required(), mcpgo.Description("ClickUp task ID.")),
		},
		g.clickupGetTask,
	)

	g.addTool(srv, "cb_clickup_get_doc",
		"Read a ClickUp Doc's page content as markdown. Accept either a full doc URL (…/v/dc/{docId}/{pageId}) or workspace_id + doc_id (+ optional page_id). Omit the page to get every page of the doc. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("url", mcpgo.Description("Full ClickUp doc URL, e.g. https://app.clickup.com/{workspace}/v/dc/{docId}/{pageId}. Use this OR workspace_id + doc_id.")),
			mcpgo.WithString("workspace_id", mcpgo.Description("ClickUp workspace/team ID. Use with doc_id when no url is given.")),
			mcpgo.WithString("doc_id", mcpgo.Description("ClickUp doc ID (e.g. 3m5v4-218736). Use with workspace_id when no url is given.")),
			mcpgo.WithString("page_id", mcpgo.Description("ClickUp doc page ID. Omit to return all pages of the doc.")),
		},
		g.clickupGetDoc,
	)

	g.addTool(srv, "cb_clickup_list_comments",
		"List comments on a ClickUp task. Returns the comment body, author, and timestamps. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("task_id", mcpgo.Required(), mcpgo.Description("ClickUp task ID.")),
			mcpgo.WithString("start_id", mcpgo.Description("Pagination cursor: only return comments older than this comment ID.")),
		},
		g.clickupListComments,
	)

	g.addTool(srv, "cb_clickup_list_members",
		"List members of a ClickUp workspace so the agent can resolve assignee IDs to names. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("workspace_id", mcpgo.Required(), mcpgo.Description("ClickUp workspace/team ID.")),
		},
		g.clickupListMembers,
	)

	g.addTool(srv, "cb_clickup_search_tasks",
		"Search tasks across an entire workspace with optional filters. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("workspace_id", mcpgo.Required(), mcpgo.Description("ClickUp workspace/team ID.")),
			mcpgo.WithString("statuses", mcpgo.Description("Comma-separated status names.")),
			mcpgo.WithString("assignees", mcpgo.Description("Comma-separated assignee user IDs.")),
			mcpgo.WithString("tags", mcpgo.Description("Comma-separated tag names.")),
			mcpgo.WithBoolean("include_closed", mcpgo.Description("Include closed tasks. Default false.")),
			mcpgo.WithNumber("page", mcpgo.Description("Page number (0-based). Default 0.")),
		},
		g.clickupSearchTasks,
	)
}

func (g *Gateway) clickupCall(ctx context.Context, token, path string, params url.Values, out any) error {
	u := clickupAPIBase + path
	if len(params) > 0 {
		u += "?" + params.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", token)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", g.UserAgent)

	resp, err := g.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("clickup http: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("clickup read: %w", err)
	}
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("clickup http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body))))
	}
	if out != nil {
		if err := json.Unmarshal(body, out); err != nil {
			return fmt.Errorf("clickup decode: %w", err)
		}
	}
	return nil
}

func (g *Gateway) clickupListWorkspaces(ctx context.Context, _ mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceClickUp)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	var resp struct {
		Teams []map[string]any `json:"teams"`
	}
	if err := g.clickupCall(ctx, cc.Payload, "/team", nil, &resp); err != nil {
		return toolErrorf("clickup list workspaces: %v", err), nil
	}
	return jsonResult(resp.Teams)
}

func (g *Gateway) clickupListSpaces(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceClickUp)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	workspaceID, err := req.RequireString("workspace_id")
	if err != nil {
		return toolErrorf("workspace_id is required"), nil
	}
	params := url.Values{}
	params.Set("archived", strconv.FormatBool(req.GetBool("archived", false)))
	var resp struct {
		Spaces []map[string]any `json:"spaces"`
	}
	if err := g.clickupCall(ctx, cc.Payload, "/team/"+workspaceID+"/space", params, &resp); err != nil {
		return toolErrorf("clickup list spaces: %v", err), nil
	}
	return jsonResult(resp.Spaces)
}

func (g *Gateway) clickupListFolders(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceClickUp)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	spaceID, err := req.RequireString("space_id")
	if err != nil {
		return toolErrorf("space_id is required"), nil
	}
	params := url.Values{}
	params.Set("archived", strconv.FormatBool(req.GetBool("archived", false)))
	var resp struct {
		Folders []map[string]any `json:"folders"`
	}
	if err := g.clickupCall(ctx, cc.Payload, "/space/"+spaceID+"/folder", params, &resp); err != nil {
		return toolErrorf("clickup list folders: %v", err), nil
	}
	return jsonResult(resp.Folders)
}

func (g *Gateway) clickupListLists(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	folderID := strings.TrimSpace(req.GetString("folder_id", ""))
	spaceID := strings.TrimSpace(req.GetString("space_id", ""))
	if (folderID == "" && spaceID == "") || (folderID != "" && spaceID != "") {
		return toolErrorf("provide exactly one of folder_id or space_id"), nil
	}
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceClickUp)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	params := url.Values{}
	params.Set("archived", strconv.FormatBool(req.GetBool("archived", false)))
	var resp struct {
		Lists []map[string]any `json:"lists"`
	}
	path := "/folder/" + folderID + "/list"
	if spaceID != "" {
		path = "/space/" + spaceID + "/list"
	}
	if err := g.clickupCall(ctx, cc.Payload, path, params, &resp); err != nil {
		return toolErrorf("clickup list lists: %v", err), nil
	}
	return jsonResult(resp.Lists)
}

func (g *Gateway) clickupListTasks(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceClickUp)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	listID, err := req.RequireString("list_id")
	if err != nil {
		return toolErrorf("list_id is required"), nil
	}
	params := url.Values{}
	params.Set("include_closed", strconv.FormatBool(req.GetBool("include_closed", false)))
	if statuses := req.GetString("statuses", ""); statuses != "" {
		for _, s := range strings.Split(statuses, ",") {
			s = strings.TrimSpace(s)
			if s != "" {
				params.Add("statuses[]", s)
			}
		}
	}
	var resp struct {
		Tasks []map[string]any `json:"tasks"`
	}
	if err := g.clickupCall(ctx, cc.Payload, "/list/"+listID+"/task", params, &resp); err != nil {
		return toolErrorf("clickup list tasks: %v", err), nil
	}
	return jsonResult(resp.Tasks)
}

func (g *Gateway) clickupGetTask(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceClickUp)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	taskID, err := req.RequireString("task_id")
	if err != nil {
		return toolErrorf("task_id is required"), nil
	}
	var task map[string]any
	if err := g.clickupCall(ctx, cc.Payload, "/task/"+taskID, nil, &task); err != nil {
		return toolErrorf("clickup get task: %v", err), nil
	}
	return jsonResult(task)
}

func (g *Gateway) clickupListComments(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceClickUp)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	taskID, err := req.RequireString("task_id")
	if err != nil {
		return toolErrorf("task_id is required"), nil
	}
	params := url.Values{}
	if startID := strings.TrimSpace(req.GetString("start_id", "")); startID != "" {
		params.Set("start_id", startID)
	}
	var resp struct {
		Comments []map[string]any `json:"comments"`
	}
	if err := g.clickupCall(ctx, cc.Payload, "/task/"+taskID+"/comment", params, &resp); err != nil {
		return toolErrorf("clickup list comments: %v", err), nil
	}
	return jsonResult(resp.Comments)
}

func (g *Gateway) clickupListMembers(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceClickUp)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	workspaceID, err := req.RequireString("workspace_id")
	if err != nil {
		return toolErrorf("workspace_id is required"), nil
	}
	// ClickUp's per-team member listing comes back from /team itself —
	// each team in the response embeds its members. Pick the matching
	// team to keep the payload minimal.
	var resp struct {
		Teams []struct {
			ID      string           `json:"id"`
			Members []map[string]any `json:"members"`
		} `json:"teams"`
	}
	if err := g.clickupCall(ctx, cc.Payload, "/team", nil, &resp); err != nil {
		return toolErrorf("clickup list members: %v", err), nil
	}
	for _, t := range resp.Teams {
		if t.ID == workspaceID {
			return jsonResult(t.Members)
		}
	}
	return toolErrorf("clickup list members: workspace %s not visible to this token", workspaceID), nil
}

func (g *Gateway) clickupSearchTasks(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceClickUp)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	workspaceID, err := req.RequireString("workspace_id")
	if err != nil {
		return toolErrorf("workspace_id is required"), nil
	}
	params := url.Values{}
	params.Set("include_closed", strconv.FormatBool(req.GetBool("include_closed", false)))
	if page := req.GetInt("page", 0); page > 0 {
		params.Set("page", strconv.Itoa(page))
	}
	for _, s := range splitCSV(req.GetString("statuses", "")) {
		params.Add("statuses[]", s)
	}
	for _, a := range splitCSV(req.GetString("assignees", "")) {
		params.Add("assignees[]", a)
	}
	for _, t := range splitCSV(req.GetString("tags", "")) {
		params.Add("tags[]", t)
	}
	var resp struct {
		Tasks    []map[string]any `json:"tasks"`
		LastPage bool             `json:"last_page"`
	}
	if err := g.clickupCall(ctx, cc.Payload, "/team/"+workspaceID+"/task", params, &resp); err != nil {
		return toolErrorf("clickup search tasks: %v", err), nil
	}
	return jsonResult(map[string]any{"tasks": resp.Tasks, "last_page": resp.LastPage})
}
