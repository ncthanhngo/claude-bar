package mcp

import (
	"bytes"
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

// gitlabService builds the multi-token MCPService key for a given instance.
// Phase 1's `shared` namespace + `:subKey` suffix per the multi-token format
// in plan.md (Red-Team Finding 15).
func gitlabService(instanceID string) domain.MCPService {
	return domain.MCPService("gitlab:" + instanceID)
}

func (g *Gateway) registerGitLabTools(srv *server.MCPServer) {
	if g.GitLabInstances == nil {
		return // GitLab not wired
	}

	addTool(srv, "cb_gitlab_list_mrs",
		"List merge requests on a self-hosted GitLab project. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name; omit when only one is configured.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path with namespace (e.g. group/repo).")),
			mcpgo.WithString("state", mcpgo.Description("opened | closed | merged | all. Default opened.")),
			mcpgo.WithNumber("per_page", mcpgo.Description("1–100. Default 20.")),
		},
		g.gitlabListMRs,
	)

	addTool(srv, "cb_gitlab_get_mr",
		"Get a single GitLab merge request.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithNumber("iid", mcpgo.Required(), mcpgo.Description("Merge request IID.")),
		},
		g.gitlabGetMR,
	)

	addTool(srv, "cb_gitlab_list_issues",
		"List issues on a GitLab project. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithString("state", mcpgo.Description("opened | closed | all. Default opened.")),
			mcpgo.WithNumber("per_page", mcpgo.Description("1–100. Default 20.")),
		},
		g.gitlabListIssues,
	)

	addTool(srv, "cb_gitlab_comment_mr",
		"Add a comment on a GitLab merge request. Gated.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithNumber("iid", mcpgo.Required(), mcpgo.Description("MR IID.")),
			mcpgo.WithString("body", mcpgo.Required(), mcpgo.Description("Comment body (markdown).")),
		},
		g.gitlabCommentMR,
	)

	addTool(srv, "cb_gitlab_approve_mr",
		"Approve a GitLab merge request. Gated.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithNumber("iid", mcpgo.Required(), mcpgo.Description("MR IID.")),
		},
		g.gitlabApproveMR,
	)

	addTool(srv, "cb_gitlab_merge_mr",
		"Merge a GitLab merge request. Destructive — surfaces modal gate.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithNumber("iid", mcpgo.Required(), mcpgo.Description("MR IID.")),
			mcpgo.WithString("commit_message", mcpgo.Description("Optional merge commit message.")),
		},
		g.gitlabMergeMR,
	)

	addTool(srv, "cb_gitlab_close_issue",
		"Close a GitLab issue. Destructive — surfaces modal gate.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithNumber("iid", mcpgo.Required(), mcpgo.Description("Issue IID.")),
		},
		g.gitlabCloseIssue,
	)
}

func (g *Gateway) gitlabResolve(ctx context.Context, ref string) (*GitLabInstance, string, error) {
	inst, err := g.GitLabInstances.Resolve(ctx, ref)
	if err != nil {
		return nil, "", err
	}
	tok, err := g.Resolver.Secrets.Read(ctx, 0, gitlabService(inst.ID))
	if err != nil {
		return inst, "", fmt.Errorf("gitlab secret read: %w", err)
	}
	if tok == "" {
		return inst, "", fmt.Errorf("gitlab instance %q has no PAT stored", inst.Name)
	}
	return inst, tok, nil
}

func (g *Gateway) gitlabAPI(ctx context.Context, inst *GitLabInstance, token, method, path string, query url.Values, body any) ([]byte, error) {
	u := strings.TrimRight(inst.BaseURL, "/") + path
	if len(query) > 0 {
		u += "?" + query.Encode()
	}
	var reader io.Reader
	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			return nil, fmt.Errorf("encode body: %w", err)
		}
		reader = bytes.NewReader(buf)
	}
	req, err := http.NewRequestWithContext(ctx, method, u, reader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("PRIVATE-TOKEN", token)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("User-Agent", g.UserAgent)

	resp, err := g.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("gitlab http: %w", err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		return b, fmt.Errorf("gitlab http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(b))))
	}
	return b, nil
}

func encodeProject(p string) string {
	return url.PathEscape(p)
}

// --- read tools ---

func (g *Gateway) gitlabListMRs(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, err := req.RequireString("project")
	if err != nil {
		return toolErrorf("project is required"), nil
	}
	q := url.Values{}
	q.Set("state", strings.TrimSpace(req.GetString("state", "opened")))
	pp := req.GetInt("per_page", 20)
	if pp < 1 {
		pp = 20
	}
	if pp > 100 {
		pp = 100
	}
	q.Set("per_page", strconv.Itoa(pp))
	body, err := g.gitlabAPI(ctx, inst, token, http.MethodGet, "/projects/"+encodeProject(project)+"/merge_requests", q, nil)
	if err != nil {
		return toolErrorf("gitlab list mrs: %v", err), nil
	}
	var out []map[string]any
	_ = json.Unmarshal(body, &out)
	return jsonResult(out)
}

func (g *Gateway) gitlabGetMR(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, err := req.RequireString("project")
	if err != nil {
		return toolErrorf("project is required"), nil
	}
	iid := req.GetInt("iid", 0)
	if iid <= 0 {
		return toolErrorf("iid is required"), nil
	}
	body, err := g.gitlabAPI(ctx, inst, token, http.MethodGet, fmt.Sprintf("/projects/%s/merge_requests/%d", encodeProject(project), iid), nil, nil)
	if err != nil {
		return toolErrorf("gitlab get mr: %v", err), nil
	}
	var out map[string]any
	_ = json.Unmarshal(body, &out)
	return jsonResult(out)
}

func (g *Gateway) gitlabListIssues(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, err := req.RequireString("project")
	if err != nil {
		return toolErrorf("project is required"), nil
	}
	q := url.Values{}
	q.Set("state", strings.TrimSpace(req.GetString("state", "opened")))
	pp := req.GetInt("per_page", 20)
	if pp < 1 {
		pp = 20
	}
	if pp > 100 {
		pp = 100
	}
	q.Set("per_page", strconv.Itoa(pp))
	body, err := g.gitlabAPI(ctx, inst, token, http.MethodGet, "/projects/"+encodeProject(project)+"/issues", q, nil)
	if err != nil {
		return toolErrorf("gitlab list issues: %v", err), nil
	}
	var out []map[string]any
	_ = json.Unmarshal(body, &out)
	return jsonResult(out)
}

// --- write tools ---

func (g *Gateway) gitlabCommentMR(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, _ := req.RequireString("project")
	iid := req.GetInt("iid", 0)
	body, _ := req.RequireString("body")
	if project == "" || iid <= 0 || strings.TrimSpace(body) == "" {
		return toolErrorf("project, iid, body are required"), nil
	}
	args := map[string]any{"instance": inst.Name, "project": project, "iid": iid, "body": body}
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_gitlab_comment_mr",
		Risk:    RiskLow,
		Origin:  OriginLLM,
		Summary: fmt.Sprintf("GitLab[%s]: comment on %s!%d", inst.Name, project, iid),
		Args:    args,
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			b, err := g.gitlabAPI(ctx, inst, token, http.MethodPost, fmt.Sprintf("/projects/%s/merge_requests/%d/notes", encodeProject(project), iid), nil, map[string]any{"body": body})
			if err != nil {
				return toolErrorf("gitlab comment: %v", err), nil
			}
			var out map[string]any
			_ = json.Unmarshal(b, &out)
			return jsonResult(out)
		},
	})
}

func (g *Gateway) gitlabApproveMR(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, _ := req.RequireString("project")
	iid := req.GetInt("iid", 0)
	if project == "" || iid <= 0 {
		return toolErrorf("project, iid are required"), nil
	}
	args := map[string]any{"instance": inst.Name, "project": project, "iid": iid}
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_gitlab_approve_mr",
		Risk:    RiskLow,
		Origin:  OriginLLM,
		Summary: fmt.Sprintf("GitLab[%s]: APPROVE %s!%d", inst.Name, project, iid),
		Args:    args,
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			b, err := g.gitlabAPI(ctx, inst, token, http.MethodPost, fmt.Sprintf("/projects/%s/merge_requests/%d/approve", encodeProject(project), iid), nil, nil)
			if err != nil {
				return toolErrorf("gitlab approve: %v", err), nil
			}
			var out map[string]any
			_ = json.Unmarshal(b, &out)
			return jsonResult(out)
		},
	})
}

func (g *Gateway) gitlabMergeMR(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, _ := req.RequireString("project")
	iid := req.GetInt("iid", 0)
	if project == "" || iid <= 0 {
		return toolErrorf("project, iid are required"), nil
	}
	commitMsg := strings.TrimSpace(req.GetString("commit_message", ""))
	args := map[string]any{"instance": inst.Name, "project": project, "iid": iid}
	if commitMsg != "" {
		args["commit_message"] = commitMsg
	}
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_gitlab_merge_mr",
		Risk:    RiskDestructive,
		Origin:  OriginLLM,
		Summary: fmt.Sprintf("GitLab[%s]: MERGE %s!%d", inst.Name, project, iid),
		Args:    args,
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			payload := map[string]any{}
			if commitMsg != "" {
				payload["merge_commit_message"] = commitMsg
			}
			b, err := g.gitlabAPI(ctx, inst, token, http.MethodPut, fmt.Sprintf("/projects/%s/merge_requests/%d/merge", encodeProject(project), iid), nil, payload)
			if err != nil {
				return toolErrorf("gitlab merge: %v", err), nil
			}
			var out map[string]any
			_ = json.Unmarshal(b, &out)
			return jsonResult(out)
		},
	})
}

func (g *Gateway) gitlabCloseIssue(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, _ := req.RequireString("project")
	iid := req.GetInt("iid", 0)
	if project == "" || iid <= 0 {
		return toolErrorf("project, iid are required"), nil
	}
	args := map[string]any{"instance": inst.Name, "project": project, "iid": iid}
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_gitlab_close_issue",
		Risk:    RiskDestructive,
		Origin:  OriginLLM,
		Summary: fmt.Sprintf("GitLab[%s]: CLOSE %s#%d", inst.Name, project, iid),
		Args:    args,
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			b, err := g.gitlabAPI(ctx, inst, token, http.MethodPut, fmt.Sprintf("/projects/%s/issues/%d", encodeProject(project), iid), nil, map[string]any{"state_event": "close"})
			if err != nil {
				return toolErrorf("gitlab close: %v", err), nil
			}
			var out map[string]any
			_ = json.Unmarshal(b, &out)
			return jsonResult(out)
		},
	})
}
