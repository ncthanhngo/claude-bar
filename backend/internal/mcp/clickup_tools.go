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
	addTool(srv, "cb_clickup_list_workspaces",
		"List ClickUp workspaces (teams) the personal API token has access to. Read-only.",
		nil,
		g.clickupListWorkspaces,
	)

	addTool(srv, "cb_clickup_list_spaces",
		"List ClickUp spaces in a workspace/team. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("workspace_id", mcpgo.Required(), mcpgo.Description("ClickUp workspace/team ID.")),
			mcpgo.WithBoolean("archived", mcpgo.Description("Include archived spaces. Default false.")),
		},
		g.clickupListSpaces,
	)

	addTool(srv, "cb_clickup_list_folders",
		"List ClickUp folders in a space. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("space_id", mcpgo.Required(), mcpgo.Description("ClickUp space ID.")),
			mcpgo.WithBoolean("archived", mcpgo.Description("Include archived folders. Default false.")),
		},
		g.clickupListFolders,
	)

	addTool(srv, "cb_clickup_list_lists",
		"List ClickUp lists in a folder or folderless space. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("folder_id", mcpgo.Description("ClickUp folder ID. Use either folder_id or space_id.")),
			mcpgo.WithString("space_id", mcpgo.Description("ClickUp space ID for folderless lists. Use either folder_id or space_id.")),
			mcpgo.WithBoolean("archived", mcpgo.Description("Include archived lists. Default false.")),
		},
		g.clickupListLists,
	)

	addTool(srv, "cb_clickup_list_tasks",
		"List ClickUp tasks for a list, optionally filtered by status and assignee. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("list_id", mcpgo.Required(), mcpgo.Description("ClickUp list ID.")),
			mcpgo.WithString("statuses", mcpgo.Description("Comma-separated status names to include.")),
			mcpgo.WithBoolean("include_closed", mcpgo.Description("Include closed tasks. Default false.")),
		},
		g.clickupListTasks,
	)

	addTool(srv, "cb_clickup_get_task",
		"Get a single ClickUp task by ID. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("task_id", mcpgo.Required(), mcpgo.Description("ClickUp task ID.")),
		},
		g.clickupGetTask,
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
