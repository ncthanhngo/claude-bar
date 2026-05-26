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

	g.addTool(srv, "cb_gitlab_list_mrs",
		"List merge requests on a self-hosted GitLab project. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name; omit when only one is configured.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path with namespace (e.g. group/repo).")),
			mcpgo.WithString("state", mcpgo.Description("opened | closed | merged | all. Default opened.")),
			mcpgo.WithNumber("per_page", mcpgo.Description("1–100. Default 20.")),
		},
		g.gitlabListMRs,
	)

	g.addTool(srv, "cb_gitlab_get_mr",
		"Get a single GitLab merge request.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithNumber("iid", mcpgo.Required(), mcpgo.Description("Merge request IID.")),
		},
		g.gitlabGetMR,
	)

	g.addTool(srv, "cb_gitlab_list_issues",
		"List issues on a GitLab project. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithString("state", mcpgo.Description("opened | closed | all. Default opened.")),
			mcpgo.WithNumber("per_page", mcpgo.Description("1–100. Default 20.")),
		},
		g.gitlabListIssues,
	)

	g.addTool(srv, "cb_gitlab_comment_mr",
		"Add a comment on a GitLab merge request. Gated.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithNumber("iid", mcpgo.Required(), mcpgo.Description("MR IID.")),
			mcpgo.WithString("body", mcpgo.Required(), mcpgo.Description("Comment body (markdown).")),
		},
		g.gitlabCommentMR,
	)

	g.addTool(srv, "cb_gitlab_approve_mr",
		"Approve a GitLab merge request. Gated.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithNumber("iid", mcpgo.Required(), mcpgo.Description("MR IID.")),
		},
		g.gitlabApproveMR,
	)

	g.addTool(srv, "cb_gitlab_merge_mr",
		"Merge a GitLab merge request. Destructive — surfaces modal gate.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithNumber("iid", mcpgo.Required(), mcpgo.Description("MR IID.")),
			mcpgo.WithString("commit_message", mcpgo.Description("Optional merge commit message.")),
		},
		g.gitlabMergeMR,
	)

	g.addTool(srv, "cb_gitlab_close_issue",
		"Close a GitLab issue. Destructive — surfaces modal gate.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithNumber("iid", mcpgo.Required(), mcpgo.Description("Issue IID.")),
		},
		g.gitlabCloseIssue,
	)

	// --- expanded reads (parity with GitHub) ---

	g.addTool(srv, "cb_gitlab_get_mr_diff",
		"Get the diff (raw patches per file) for a GitLab merge request. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithNumber("iid", mcpgo.Required(), mcpgo.Description("MR IID.")),
		},
		g.gitlabGetMRDiff,
	)

	g.addTool(srv, "cb_gitlab_list_mr_notes",
		"List discussion comments (notes) on a merge request. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithNumber("iid", mcpgo.Required(), mcpgo.Description("MR IID.")),
			mcpgo.WithNumber("per_page", mcpgo.Description("1–100. Default 20.")),
		},
		g.gitlabListMRNotes,
	)

	g.addTool(srv, "cb_gitlab_list_mr_changes",
		"List files changed in a merge request with patch hunks. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithNumber("iid", mcpgo.Required(), mcpgo.Description("MR IID.")),
		},
		g.gitlabListMRChanges,
	)

	g.addTool(srv, "cb_gitlab_get_issue",
		"Get one GitLab issue by IID. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithNumber("iid", mcpgo.Required(), mcpgo.Description("Issue IID.")),
		},
		g.gitlabGetIssue,
	)

	g.addTool(srv, "cb_gitlab_list_issue_notes",
		"List discussion comments (notes) on an issue. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithNumber("iid", mcpgo.Required(), mcpgo.Description("Issue IID.")),
			mcpgo.WithNumber("per_page", mcpgo.Description("1–100. Default 20.")),
		},
		g.gitlabListIssueNotes,
	)

	g.addTool(srv, "cb_gitlab_get_file",
		"Read a file from a GitLab repository at a given ref. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithString("path", mcpgo.Required(), mcpgo.Description("File path relative to repo root.")),
			mcpgo.WithString("ref", mcpgo.Description("Branch, tag, or commit SHA. Default project default branch.")),
		},
		g.gitlabGetFile,
	)

	g.addTool(srv, "cb_gitlab_list_branches",
		"List branches in a GitLab project. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithString("search", mcpgo.Description("Filter to branches matching this substring.")),
			mcpgo.WithNumber("per_page", mcpgo.Description("1–100. Default 20.")),
		},
		g.gitlabListBranches,
	)

	g.addTool(srv, "cb_gitlab_list_commits",
		"List commits on a branch or path. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithString("ref_name", mcpgo.Description("Branch / tag / SHA. Default default branch.")),
			mcpgo.WithString("path", mcpgo.Description("Filter to commits touching this path.")),
			mcpgo.WithNumber("per_page", mcpgo.Description("1–100. Default 20.")),
		},
		g.gitlabListCommits,
	)

	g.addTool(srv, "cb_gitlab_list_pipelines",
		"List CI pipelines for a project, optionally filtered by ref / status. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithString("ref", mcpgo.Description("Branch or tag to filter on.")),
			mcpgo.WithString("status", mcpgo.Description("running | pending | success | failed | canceled | skipped | manual.")),
			mcpgo.WithNumber("per_page", mcpgo.Description("1–100. Default 20.")),
		},
		g.gitlabListPipelines,
	)

	// --- expanded writes ---

	g.addTool(srv, "cb_gitlab_create_issue",
		"Open a new GitLab issue. Gated.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithString("title", mcpgo.Required(), mcpgo.Description("Issue title.")),
			mcpgo.WithString("description", mcpgo.Description("Issue body (markdown).")),
			mcpgo.WithString("labels", mcpgo.Description("Comma-separated labels.")),
			mcpgo.WithString("assignee_ids", mcpgo.Description("Comma-separated GitLab user IDs.")),
		},
		g.gitlabCreateIssue,
	)

	g.addTool(srv, "cb_gitlab_create_mr",
		"Open a new merge request. Gated.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithString("title", mcpgo.Required(), mcpgo.Description("MR title.")),
			mcpgo.WithString("source_branch", mcpgo.Required(), mcpgo.Description("Source branch.")),
			mcpgo.WithString("target_branch", mcpgo.Required(), mcpgo.Description("Target branch.")),
			mcpgo.WithString("description", mcpgo.Description("MR description (markdown).")),
			mcpgo.WithBoolean("draft", mcpgo.Description("Open as draft (Draft: prefix). Default false.")),
			mcpgo.WithBoolean("remove_source_branch", mcpgo.Description("Delete source branch on merge. Default true.")),
		},
		g.gitlabCreateMR,
	)

	g.addTool(srv, "cb_gitlab_update_issue",
		"Edit a GitLab issue's title, description, labels, or assignees. Gated. Use cb_gitlab_close_issue for state changes.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("instance", mcpgo.Description("Instance id or name.")),
			mcpgo.WithString("project", mcpgo.Required(), mcpgo.Description("Project path.")),
			mcpgo.WithNumber("iid", mcpgo.Required(), mcpgo.Description("Issue IID.")),
			mcpgo.WithString("title", mcpgo.Description("New title.")),
			mcpgo.WithString("description", mcpgo.Description("New description (markdown).")),
			mcpgo.WithString("labels", mcpgo.Description("Comma-separated labels — REPLACES current set.")),
			mcpgo.WithString("assignee_ids", mcpgo.Description("Comma-separated user IDs — REPLACES current set.")),
		},
		g.gitlabUpdateIssue,
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

// --- expanded read handlers ---

func (g *Gateway) gitlabResolveProjectIID(req mcpgo.CallToolRequest) (string, int, *mcpgo.CallToolResult) {
	project, err := req.RequireString("project")
	if err != nil {
		return "", 0, toolErrorf("project is required")
	}
	iid := req.GetInt("iid", 0)
	if iid <= 0 {
		return "", 0, toolErrorf("iid is required")
	}
	return project, iid, nil
}

func (g *Gateway) gitlabGetMRDiff(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, iid, errRes := g.gitlabResolveProjectIID(req)
	if errRes != nil {
		return errRes, nil
	}
	body, err := g.gitlabAPI(ctx, inst, token, http.MethodGet, fmt.Sprintf("/projects/%s/merge_requests/%d/diffs", encodeProject(project), iid), nil, nil)
	if err != nil {
		return toolErrorf("gitlab mr diff: %v", err), nil
	}
	var out []map[string]any
	_ = json.Unmarshal(body, &out)
	return jsonResult(out)
}

func (g *Gateway) gitlabListMRNotes(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	return g.gitlabListChildNotes(ctx, req, "merge_requests", "list mr notes")
}

func (g *Gateway) gitlabListIssueNotes(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	return g.gitlabListChildNotes(ctx, req, "issues", "list issue notes")
}

func (g *Gateway) gitlabListChildNotes(ctx context.Context, req mcpgo.CallToolRequest, parent, label string) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, iid, errRes := g.gitlabResolveProjectIID(req)
	if errRes != nil {
		return errRes, nil
	}
	q := url.Values{}
	pp := req.GetInt("per_page", 20)
	if pp < 1 {
		pp = 20
	}
	if pp > 100 {
		pp = 100
	}
	q.Set("per_page", strconv.Itoa(pp))
	body, err := g.gitlabAPI(ctx, inst, token, http.MethodGet, fmt.Sprintf("/projects/%s/%s/%d/notes", encodeProject(project), parent, iid), q, nil)
	if err != nil {
		return toolErrorf("gitlab %s: %v", label, err), nil
	}
	var out []map[string]any
	_ = json.Unmarshal(body, &out)
	return jsonResult(out)
}

func (g *Gateway) gitlabListMRChanges(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, iid, errRes := g.gitlabResolveProjectIID(req)
	if errRes != nil {
		return errRes, nil
	}
	body, err := g.gitlabAPI(ctx, inst, token, http.MethodGet, fmt.Sprintf("/projects/%s/merge_requests/%d/changes", encodeProject(project), iid), nil, nil)
	if err != nil {
		return toolErrorf("gitlab mr changes: %v", err), nil
	}
	var out map[string]any
	_ = json.Unmarshal(body, &out)
	return jsonResult(out)
}

func (g *Gateway) gitlabGetIssue(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, iid, errRes := g.gitlabResolveProjectIID(req)
	if errRes != nil {
		return errRes, nil
	}
	body, err := g.gitlabAPI(ctx, inst, token, http.MethodGet, fmt.Sprintf("/projects/%s/issues/%d", encodeProject(project), iid), nil, nil)
	if err != nil {
		return toolErrorf("gitlab get issue: %v", err), nil
	}
	var out map[string]any
	_ = json.Unmarshal(body, &out)
	return jsonResult(out)
}

func (g *Gateway) gitlabGetFile(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, err := req.RequireString("project")
	if err != nil {
		return toolErrorf("project is required"), nil
	}
	path, err := req.RequireString("path")
	if err != nil {
		return toolErrorf("path is required"), nil
	}
	ref := strings.TrimSpace(req.GetString("ref", ""))
	q := url.Values{}
	if ref != "" {
		q.Set("ref", ref)
	}
	// GitLab Repository Files API uses /raw to return the file bytes directly.
	body, err := g.gitlabAPI(ctx, inst, token, http.MethodGet, fmt.Sprintf("/projects/%s/repository/files/%s/raw", encodeProject(project), url.PathEscape(path)), q, nil)
	if err != nil {
		return toolErrorf("gitlab get file: %v", err), nil
	}
	return mcpgo.NewToolResultText(string(body)), nil
}

func (g *Gateway) gitlabListBranches(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, err := req.RequireString("project")
	if err != nil {
		return toolErrorf("project is required"), nil
	}
	q := url.Values{}
	if s := strings.TrimSpace(req.GetString("search", "")); s != "" {
		q.Set("search", s)
	}
	pp := req.GetInt("per_page", 20)
	if pp < 1 {
		pp = 20
	}
	if pp > 100 {
		pp = 100
	}
	q.Set("per_page", strconv.Itoa(pp))
	body, err := g.gitlabAPI(ctx, inst, token, http.MethodGet, "/projects/"+encodeProject(project)+"/repository/branches", q, nil)
	if err != nil {
		return toolErrorf("gitlab list branches: %v", err), nil
	}
	var out []map[string]any
	_ = json.Unmarshal(body, &out)
	return jsonResult(out)
}

func (g *Gateway) gitlabListCommits(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, err := req.RequireString("project")
	if err != nil {
		return toolErrorf("project is required"), nil
	}
	q := url.Values{}
	if v := strings.TrimSpace(req.GetString("ref_name", "")); v != "" {
		q.Set("ref_name", v)
	}
	if v := strings.TrimSpace(req.GetString("path", "")); v != "" {
		q.Set("path", v)
	}
	pp := req.GetInt("per_page", 20)
	if pp < 1 {
		pp = 20
	}
	if pp > 100 {
		pp = 100
	}
	q.Set("per_page", strconv.Itoa(pp))
	body, err := g.gitlabAPI(ctx, inst, token, http.MethodGet, "/projects/"+encodeProject(project)+"/repository/commits", q, nil)
	if err != nil {
		return toolErrorf("gitlab list commits: %v", err), nil
	}
	var out []map[string]any
	_ = json.Unmarshal(body, &out)
	return jsonResult(out)
}

func (g *Gateway) gitlabListPipelines(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, err := req.RequireString("project")
	if err != nil {
		return toolErrorf("project is required"), nil
	}
	q := url.Values{}
	if v := strings.TrimSpace(req.GetString("ref", "")); v != "" {
		q.Set("ref", v)
	}
	if v := strings.TrimSpace(req.GetString("status", "")); v != "" {
		q.Set("status", v)
	}
	pp := req.GetInt("per_page", 20)
	if pp < 1 {
		pp = 20
	}
	if pp > 100 {
		pp = 100
	}
	q.Set("per_page", strconv.Itoa(pp))
	body, err := g.gitlabAPI(ctx, inst, token, http.MethodGet, "/projects/"+encodeProject(project)+"/pipelines", q, nil)
	if err != nil {
		return toolErrorf("gitlab list pipelines: %v", err), nil
	}
	var out []map[string]any
	_ = json.Unmarshal(body, &out)
	return jsonResult(out)
}

// --- expanded write handlers ---

func parseCSVStrings(s string) []string {
	out := []string{}
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func (g *Gateway) gitlabCreateIssue(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, err := req.RequireString("project")
	if err != nil {
		return toolErrorf("project is required"), nil
	}
	title, err := req.RequireString("title")
	if err != nil || strings.TrimSpace(title) == "" {
		return toolErrorf("title is required"), nil
	}
	description := req.GetString("description", "")
	labels := parseCSVStrings(req.GetString("labels", ""))
	assigneeIDs := parseCSVInts(req.GetString("assignee_ids", ""))

	payload := map[string]any{"title": title}
	if description != "" {
		payload["description"] = description
	}
	if len(labels) > 0 {
		payload["labels"] = strings.Join(labels, ",")
	}
	if len(assigneeIDs) > 0 {
		payload["assignee_ids"] = assigneeIDs
	}

	args := map[string]any{"instance": inst.Name, "project": project, "title": title}
	if description != "" {
		args["description"] = description
	}
	if len(labels) > 0 {
		args["labels"] = labels
	}
	if len(assigneeIDs) > 0 {
		args["assignee_ids"] = assigneeIDs
	}

	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_gitlab_create_issue",
		Risk:    RiskLow,
		Origin:  OriginLLM,
		Summary: fmt.Sprintf("GitLab[%s]: open issue in %s — %s", inst.Name, project, title),
		Args:    args,
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			b, err := g.gitlabAPI(ctx, inst, token, http.MethodPost, "/projects/"+encodeProject(project)+"/issues", nil, payload)
			if err != nil {
				return toolErrorf("gitlab create issue: %v", err), nil
			}
			var out map[string]any
			_ = json.Unmarshal(b, &out)
			return jsonResult(out)
		},
	})
}

func (g *Gateway) gitlabCreateMR(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, err := req.RequireString("project")
	if err != nil {
		return toolErrorf("project is required"), nil
	}
	title, err := req.RequireString("title")
	if err != nil || strings.TrimSpace(title) == "" {
		return toolErrorf("title is required"), nil
	}
	sourceBranch, err := req.RequireString("source_branch")
	if err != nil || strings.TrimSpace(sourceBranch) == "" {
		return toolErrorf("source_branch is required"), nil
	}
	targetBranch, err := req.RequireString("target_branch")
	if err != nil || strings.TrimSpace(targetBranch) == "" {
		return toolErrorf("target_branch is required"), nil
	}
	description := req.GetString("description", "")
	draft := req.GetBool("draft", false)
	removeSourceBranch := req.GetBool("remove_source_branch", true)

	finalTitle := title
	if draft && !strings.HasPrefix(strings.ToLower(title), "draft:") {
		finalTitle = "Draft: " + title
	}

	payload := map[string]any{
		"title":                finalTitle,
		"source_branch":        sourceBranch,
		"target_branch":        targetBranch,
		"remove_source_branch": removeSourceBranch,
	}
	if description != "" {
		payload["description"] = description
	}

	args := map[string]any{
		"instance": inst.Name, "project": project,
		"title": finalTitle, "source_branch": sourceBranch, "target_branch": targetBranch,
		"draft": draft,
	}
	if description != "" {
		args["description"] = description
	}
	risk := RiskMedium
	if draft {
		risk = RiskLow
	}

	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_gitlab_create_mr",
		Risk:    risk,
		Origin:  OriginLLM,
		Summary: fmt.Sprintf("GitLab[%s]: open MR %s %s ← %s — %s", inst.Name, project, targetBranch, sourceBranch, finalTitle),
		Args:    args,
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			b, err := g.gitlabAPI(ctx, inst, token, http.MethodPost, "/projects/"+encodeProject(project)+"/merge_requests", nil, payload)
			if err != nil {
				return toolErrorf("gitlab create mr: %v", err), nil
			}
			var out map[string]any
			_ = json.Unmarshal(b, &out)
			return jsonResult(out)
		},
	})
}

func (g *Gateway) gitlabUpdateIssue(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	inst, token, err := g.gitlabResolve(ctx, req.GetString("instance", ""))
	if err != nil {
		return toolErrorf("gitlab: %v", err), nil
	}
	project, iid, errRes := g.gitlabResolveProjectIID(req)
	if errRes != nil {
		return errRes, nil
	}

	supplied := req.GetArguments()
	payload := map[string]any{}
	if v, ok := supplied["title"]; ok {
		if s, _ := v.(string); strings.TrimSpace(s) != "" {
			payload["title"] = s
		} else {
			return toolErrorf("title must not be empty"), nil
		}
	}
	if v, ok := supplied["description"]; ok {
		s, _ := v.(string)
		payload["description"] = s
	}
	if v, ok := supplied["labels"]; ok {
		if s, _ := v.(string); true {
			payload["labels"] = strings.Join(parseCSVStrings(s), ",")
		}
	}
	if v, ok := supplied["assignee_ids"]; ok {
		if s, _ := v.(string); true {
			payload["assignee_ids"] = parseCSVInts(s)
		}
	}
	if len(payload) == 0 {
		return toolErrorf("at least one of title, description, labels, assignee_ids must be provided"), nil
	}

	args := map[string]any{"instance": inst.Name, "project": project, "iid": iid}
	for k, v := range payload {
		args[k] = v
	}
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_gitlab_update_issue",
		Risk:    RiskLow,
		Origin:  OriginLLM,
		Summary: fmt.Sprintf("GitLab[%s]: edit %s#%d (%d field%s)", inst.Name, project, iid, len(payload), plural(len(payload))),
		Args:    args,
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			b, err := g.gitlabAPI(ctx, inst, token, http.MethodPut, fmt.Sprintf("/projects/%s/issues/%d", encodeProject(project), iid), nil, payload)
			if err != nil {
				return toolErrorf("gitlab update issue: %v", err), nil
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
