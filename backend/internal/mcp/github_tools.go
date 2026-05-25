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

// registerGitHubTools registers GitHub read tools. Descriptions are kept
// terse on purpose — every word ships in tools/list for every Claude Code
// message in the session, and self-explanatory fields (owner, repo, number)
// don't need help text. See PR notes on the v10.34 → v10.35 schema slim.
func (g *Gateway) registerGitHubTools(srv *server.MCPServer) {
	owner := mcpgo.WithString("owner", mcpgo.Required())
	repo := mcpgo.WithString("repo", mcpgo.Required())
	prNum := mcpgo.WithNumber("number", mcpgo.Required())
	perPage := mcpgo.WithNumber("per_page", mcpgo.Description("1–100, default 30."))

	addTool(srv, "cb_github_list_prs", "List PRs.",
		[]mcpgo.ToolOption{
			owner, repo,
			mcpgo.WithString("state", mcpgo.Description("open|closed|all.")),
			mcpgo.WithString("sort", mcpgo.Description("created|updated|popularity|long-running.")),
			perPage,
		},
		g.githubListPRs,
	)

	addTool(srv, "cb_github_get_pr", "Get a PR.",
		[]mcpgo.ToolOption{owner, repo, prNum},
		g.githubGetPR,
	)

	addTool(srv, "cb_github_get_pr_diff", "Get PR unified diff.",
		[]mcpgo.ToolOption{owner, repo, prNum},
		g.githubGetPRDiff,
	)

	addTool(srv, "cb_github_list_issues", "List issues (excludes PRs).",
		[]mcpgo.ToolOption{
			owner, repo,
			mcpgo.WithString("state", mcpgo.Description("open|closed|all.")),
			mcpgo.WithString("labels", mcpgo.Description("CSV label names.")),
			perPage,
		},
		g.githubListIssues,
	)

	addTool(srv, "cb_github_search_code", "Search code (GitHub query syntax).",
		[]mcpgo.ToolOption{
			mcpgo.WithString("query", mcpgo.Required()),
			perPage,
		},
		g.githubSearchCode,
	)

	addTool(srv, "cb_github_search_issues", "Search issues/PRs (GitHub query syntax).",
		[]mcpgo.ToolOption{
			mcpgo.WithString("query", mcpgo.Required()),
			mcpgo.WithString("sort", mcpgo.Description("comments|reactions|created|updated.")),
			perPage,
		},
		g.githubSearchIssues,
	)

	addTool(srv, "cb_github_get_issue", "Get an issue.",
		[]mcpgo.ToolOption{owner, repo, prNum},
		g.githubGetIssue,
	)

	addTool(srv, "cb_github_list_issue_comments", "List comments on issue/PR.",
		[]mcpgo.ToolOption{owner, repo, prNum, perPage},
		g.githubListIssueComments,
	)

	addTool(srv, "cb_github_list_pr_reviews", "List PR reviews (APPROVED/CHANGES_REQUESTED/COMMENTED).",
		[]mcpgo.ToolOption{owner, repo, prNum, perPage},
		g.githubListPRReviews,
	)

	addTool(srv, "cb_github_list_pr_review_comments", "List inline PR review comments.",
		[]mcpgo.ToolOption{owner, repo, prNum, perPage},
		g.githubListPRReviewComments,
	)

	addTool(srv, "cb_github_list_pr_files", "List PR files with patches.",
		[]mcpgo.ToolOption{owner, repo, prNum, perPage},
		g.githubListPRFiles,
	)

	addTool(srv, "cb_github_list_pr_commits", "List PR commits.",
		[]mcpgo.ToolOption{owner, repo, prNum, perPage},
		g.githubListPRCommits,
	)

	addTool(srv, "cb_github_get_file_content", "Read a file at ref.",
		[]mcpgo.ToolOption{
			owner, repo,
			mcpgo.WithString("path", mcpgo.Required()),
			mcpgo.WithString("ref", mcpgo.Description("Branch/tag/SHA. Default repo default branch.")),
		},
		g.githubGetFileContent,
	)

	addTool(srv, "cb_github_list_commits", "List commits.",
		[]mcpgo.ToolOption{
			owner, repo,
			mcpgo.WithString("sha", mcpgo.Description("Branch/tag/SHA to start from.")),
			mcpgo.WithString("path", mcpgo.Description("Filter to this path.")),
			mcpgo.WithString("author", mcpgo.Description("Login or email.")),
			perPage,
		},
		g.githubListCommits,
	)

	addTool(srv, "cb_github_get_commit", "Get a commit with patches.",
		[]mcpgo.ToolOption{
			owner, repo,
			mcpgo.WithString("ref", mcpgo.Required(), mcpgo.Description("SHA/branch/tag.")),
		},
		g.githubGetCommit,
	)

	addTool(srv, "cb_github_list_branches", "List branches.",
		[]mcpgo.ToolOption{
			owner, repo,
			mcpgo.WithBoolean("protected", mcpgo.Description("Only protected.")),
			perPage,
		},
		g.githubListBranches,
	)

	addTool(srv, "cb_github_list_check_runs", "List CI check runs at ref.",
		[]mcpgo.ToolOption{
			owner, repo,
			mcpgo.WithString("ref", mcpgo.Required(), mcpgo.Description("SHA/branch/tag.")),
			mcpgo.WithString("status", mcpgo.Description("queued|in_progress|completed.")),
			perPage,
		},
		g.githubListCheckRuns,
	)

	addTool(srv, "cb_github_list_workflow_runs", "List Actions workflow runs.",
		[]mcpgo.ToolOption{
			owner, repo,
			mcpgo.WithString("branch"),
			mcpgo.WithString("status", mcpgo.Description("queued|in_progress|completed|success|failure|cancelled.")),
			mcpgo.WithString("event", mcpgo.Description("push|pull_request|schedule|workflow_dispatch.")),
			perPage,
		},
		g.githubListWorkflowRuns,
	)
}

func (g *Gateway) githubResolveAndToken(ctx context.Context) (*CallContext, string, *mcpgo.CallToolResult) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceGitHub)
	if err != nil {
		return nil, "", toolErrorForResolve(err)
	}
	token, err := g.githubRefresh(ctx, cc)
	if err != nil {
		return nil, "", toolErrorf("github refresh: %v", err)
	}
	if token == "" {
		return nil, "", toolErrorf("github: empty access token (reconnect required)")
	}
	return cc, token, nil
}

// githubCall issues a GET against the GitHub REST API. `path` is the URL path
// (e.g. "/repos/o/r/pulls"). `accept` overrides the default JSON Accept header
// — used to fetch the diff (`application/vnd.github.diff`).
func (g *Gateway) githubCall(ctx context.Context, token, path string, params url.Values, accept string) ([]byte, int, error) {
	u := githubAPIEndpoint() + path
	if len(params) > 0 {
		u += "?" + params.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if accept == "" {
		accept = "application/vnd.github+json"
	}
	req.Header.Set("Accept", accept)
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("User-Agent", g.UserAgent)

	resp, err := g.HTTP.Do(req)
	if err != nil {
		return nil, 0, fmt.Errorf("github http: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, resp.StatusCode, fmt.Errorf("github read: %w", err)
	}
	if resp.StatusCode/100 != 2 {
		return body, resp.StatusCode, fmt.Errorf("github http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body))))
	}
	return body, resp.StatusCode, nil
}

func (g *Gateway) githubListPRs(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	_, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	owner, err := req.RequireString("owner")
	if err != nil {
		return toolErrorf("owner is required"), nil
	}
	repo, err := req.RequireString("repo")
	if err != nil {
		return toolErrorf("repo is required"), nil
	}
	params := url.Values{}
	if v := strings.TrimSpace(req.GetString("state", "")); v != "" {
		params.Set("state", v)
	}
	if v := strings.TrimSpace(req.GetString("sort", "")); v != "" {
		params.Set("sort", v)
	}
	if v := req.GetInt("per_page", 0); v > 0 {
		params.Set("per_page", strconv.Itoa(clampPerPage(v)))
	}
	body, _, err := g.githubCall(ctx, token, "/repos/"+owner+"/"+repo+"/pulls", params, "")
	if err != nil {
		return toolErrorf("github list prs: %v", err), nil
	}
	var out []map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return toolErrorf("github decode: %v", err), nil
	}
	return jsonResult(out)
}

func (g *Gateway) githubGetPR(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	_, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	owner, err := req.RequireString("owner")
	if err != nil {
		return toolErrorf("owner is required"), nil
	}
	repo, err := req.RequireString("repo")
	if err != nil {
		return toolErrorf("repo is required"), nil
	}
	num := req.GetInt("number", 0)
	if num <= 0 {
		return toolErrorf("number is required and must be positive"), nil
	}
	body, _, err := g.githubCall(ctx, token, fmt.Sprintf("/repos/%s/%s/pulls/%d", owner, repo, num), nil, "")
	if err != nil {
		return toolErrorf("github get pr: %v", err), nil
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return toolErrorf("github decode: %v", err), nil
	}
	return jsonResult(out)
}

func (g *Gateway) githubGetPRDiff(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	_, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	owner, err := req.RequireString("owner")
	if err != nil {
		return toolErrorf("owner is required"), nil
	}
	repo, err := req.RequireString("repo")
	if err != nil {
		return toolErrorf("repo is required"), nil
	}
	num := req.GetInt("number", 0)
	if num <= 0 {
		return toolErrorf("number is required and must be positive"), nil
	}
	body, _, err := g.githubCall(ctx, token, fmt.Sprintf("/repos/%s/%s/pulls/%d", owner, repo, num), nil, "application/vnd.github.diff")
	if err != nil {
		return toolErrorf("github get pr diff: %v", err), nil
	}
	return mcpgo.NewToolResultText(string(body)), nil
}

func (g *Gateway) githubListIssues(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	_, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	owner, err := req.RequireString("owner")
	if err != nil {
		return toolErrorf("owner is required"), nil
	}
	repo, err := req.RequireString("repo")
	if err != nil {
		return toolErrorf("repo is required"), nil
	}
	params := url.Values{}
	if v := strings.TrimSpace(req.GetString("state", "")); v != "" {
		params.Set("state", v)
	}
	if v := strings.TrimSpace(req.GetString("labels", "")); v != "" {
		params.Set("labels", v)
	}
	if v := req.GetInt("per_page", 0); v > 0 {
		params.Set("per_page", strconv.Itoa(clampPerPage(v)))
	}
	body, _, err := g.githubCall(ctx, token, "/repos/"+owner+"/"+repo+"/issues", params, "")
	if err != nil {
		return toolErrorf("github list issues: %v", err), nil
	}
	var raw []map[string]any
	if err := json.Unmarshal(body, &raw); err != nil {
		return toolErrorf("github decode: %v", err), nil
	}
	// GitHub returns PRs in /issues — strip them to match the tool description.
	out := make([]map[string]any, 0, len(raw))
	for _, it := range raw {
		if _, isPR := it["pull_request"]; isPR {
			continue
		}
		out = append(out, it)
	}
	return jsonResult(out)
}

func (g *Gateway) githubSearchCode(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	_, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	query, err := req.RequireString("query")
	if err != nil {
		return toolErrorf("query is required"), nil
	}
	params := url.Values{}
	params.Set("q", query)
	if v := req.GetInt("per_page", 0); v > 0 {
		params.Set("per_page", strconv.Itoa(clampPerPage(v)))
	}
	body, _, err := g.githubCall(ctx, token, "/search/code", params, "")
	if err != nil {
		return toolErrorf("github search code: %v", err), nil
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return toolErrorf("github decode: %v", err), nil
	}
	return jsonResult(out)
}

func (g *Gateway) githubSearchIssues(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	_, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	query, err := req.RequireString("query")
	if err != nil {
		return toolErrorf("query is required"), nil
	}
	params := url.Values{}
	params.Set("q", query)
	if v := strings.TrimSpace(req.GetString("sort", "")); v != "" {
		params.Set("sort", v)
	}
	if v := req.GetInt("per_page", 0); v > 0 {
		params.Set("per_page", strconv.Itoa(clampPerPage(v)))
	}
	body, _, err := g.githubCall(ctx, token, "/search/issues", params, "")
	if err != nil {
		return toolErrorf("github search issues: %v", err), nil
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return toolErrorf("github decode: %v", err), nil
	}
	return jsonResult(out)
}

func (g *Gateway) githubGetIssue(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	_, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	owner, repo, num, errRes := requireOwnerRepoNumber(req)
	if errRes != nil {
		return errRes, nil
	}
	body, _, err := g.githubCall(ctx, token, fmt.Sprintf("/repos/%s/%s/issues/%d", owner, repo, num), nil, "")
	if err != nil {
		return toolErrorf("github get issue: %v", err), nil
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return toolErrorf("github decode: %v", err), nil
	}
	return jsonResult(out)
}

func (g *Gateway) githubListIssueComments(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	return g.githubListPRChildren(ctx, req, "issues", "comments", "list issue comments")
}

func (g *Gateway) githubListPRReviews(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	return g.githubListPRChildren(ctx, req, "pulls", "reviews", "list pr reviews")
}

func (g *Gateway) githubListPRReviewComments(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	return g.githubListPRChildren(ctx, req, "pulls", "comments", "list pr review comments")
}

func (g *Gateway) githubListPRFiles(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	return g.githubListPRChildren(ctx, req, "pulls", "files", "list pr files")
}

func (g *Gateway) githubListPRCommits(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	return g.githubListPRChildren(ctx, req, "pulls", "commits", "list pr commits")
}

// githubListPRChildren is the shared GET-list shape used by the five
// PR/issue sub-resource endpoints. Each lives at
// /repos/{o}/{r}/{parent}/{n}/{child} and returns a JSON array.
func (g *Gateway) githubListPRChildren(ctx context.Context, req mcpgo.CallToolRequest, parent, child, label string) (*mcpgo.CallToolResult, error) {
	_, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	owner, repo, num, errRes := requireOwnerRepoNumber(req)
	if errRes != nil {
		return errRes, nil
	}
	params := url.Values{}
	if v := req.GetInt("per_page", 0); v > 0 {
		params.Set("per_page", strconv.Itoa(clampPerPage(v)))
	}
	body, _, err := g.githubCall(ctx, token, fmt.Sprintf("/repos/%s/%s/%s/%d/%s", owner, repo, parent, num, child), params, "")
	if err != nil {
		return toolErrorf("github %s: %v", label, err), nil
	}
	var out []map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return toolErrorf("github decode: %v", err), nil
	}
	return jsonResult(out)
}

func (g *Gateway) githubGetFileContent(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	_, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	owner, err := req.RequireString("owner")
	if err != nil {
		return toolErrorf("owner is required"), nil
	}
	repo, err := req.RequireString("repo")
	if err != nil {
		return toolErrorf("repo is required"), nil
	}
	path, err := req.RequireString("path")
	if err != nil {
		return toolErrorf("path is required"), nil
	}
	params := url.Values{}
	if ref := strings.TrimSpace(req.GetString("ref", "")); ref != "" {
		params.Set("ref", ref)
	}
	body, _, err := g.githubCall(ctx, token, "/repos/"+owner+"/"+repo+"/contents/"+escapePath(path), params, "application/vnd.github.raw")
	if err != nil {
		return toolErrorf("github get file content: %v", err), nil
	}
	return mcpgo.NewToolResultText(string(body)), nil
}

func (g *Gateway) githubListCommits(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	_, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	owner, err := req.RequireString("owner")
	if err != nil {
		return toolErrorf("owner is required"), nil
	}
	repo, err := req.RequireString("repo")
	if err != nil {
		return toolErrorf("repo is required"), nil
	}
	params := url.Values{}
	if v := strings.TrimSpace(req.GetString("sha", "")); v != "" {
		params.Set("sha", v)
	}
	if v := strings.TrimSpace(req.GetString("path", "")); v != "" {
		params.Set("path", v)
	}
	if v := strings.TrimSpace(req.GetString("author", "")); v != "" {
		params.Set("author", v)
	}
	if v := req.GetInt("per_page", 0); v > 0 {
		params.Set("per_page", strconv.Itoa(clampPerPage(v)))
	}
	body, _, err := g.githubCall(ctx, token, "/repos/"+owner+"/"+repo+"/commits", params, "")
	if err != nil {
		return toolErrorf("github list commits: %v", err), nil
	}
	var out []map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return toolErrorf("github decode: %v", err), nil
	}
	return jsonResult(out)
}

func (g *Gateway) githubGetCommit(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	_, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	owner, err := req.RequireString("owner")
	if err != nil {
		return toolErrorf("owner is required"), nil
	}
	repo, err := req.RequireString("repo")
	if err != nil {
		return toolErrorf("repo is required"), nil
	}
	ref, err := req.RequireString("ref")
	if err != nil {
		return toolErrorf("ref is required"), nil
	}
	body, _, err := g.githubCall(ctx, token, "/repos/"+owner+"/"+repo+"/commits/"+ref, nil, "")
	if err != nil {
		return toolErrorf("github get commit: %v", err), nil
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return toolErrorf("github decode: %v", err), nil
	}
	return jsonResult(out)
}

func (g *Gateway) githubListBranches(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	_, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	owner, err := req.RequireString("owner")
	if err != nil {
		return toolErrorf("owner is required"), nil
	}
	repo, err := req.RequireString("repo")
	if err != nil {
		return toolErrorf("repo is required"), nil
	}
	params := url.Values{}
	if req.GetBool("protected", false) {
		params.Set("protected", "true")
	}
	if v := req.GetInt("per_page", 0); v > 0 {
		params.Set("per_page", strconv.Itoa(clampPerPage(v)))
	}
	body, _, err := g.githubCall(ctx, token, "/repos/"+owner+"/"+repo+"/branches", params, "")
	if err != nil {
		return toolErrorf("github list branches: %v", err), nil
	}
	var out []map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return toolErrorf("github decode: %v", err), nil
	}
	return jsonResult(out)
}

func (g *Gateway) githubListCheckRuns(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	_, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	owner, err := req.RequireString("owner")
	if err != nil {
		return toolErrorf("owner is required"), nil
	}
	repo, err := req.RequireString("repo")
	if err != nil {
		return toolErrorf("repo is required"), nil
	}
	ref, err := req.RequireString("ref")
	if err != nil {
		return toolErrorf("ref is required"), nil
	}
	params := url.Values{}
	if v := strings.TrimSpace(req.GetString("status", "")); v != "" {
		params.Set("status", v)
	}
	if v := req.GetInt("per_page", 0); v > 0 {
		params.Set("per_page", strconv.Itoa(clampPerPage(v)))
	}
	body, _, err := g.githubCall(ctx, token, "/repos/"+owner+"/"+repo+"/commits/"+ref+"/check-runs", params, "")
	if err != nil {
		return toolErrorf("github list check runs: %v", err), nil
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return toolErrorf("github decode: %v", err), nil
	}
	return jsonResult(out)
}

func (g *Gateway) githubListWorkflowRuns(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	_, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	owner, err := req.RequireString("owner")
	if err != nil {
		return toolErrorf("owner is required"), nil
	}
	repo, err := req.RequireString("repo")
	if err != nil {
		return toolErrorf("repo is required"), nil
	}
	params := url.Values{}
	if v := strings.TrimSpace(req.GetString("branch", "")); v != "" {
		params.Set("branch", v)
	}
	if v := strings.TrimSpace(req.GetString("status", "")); v != "" {
		params.Set("status", v)
	}
	if v := strings.TrimSpace(req.GetString("event", "")); v != "" {
		params.Set("event", v)
	}
	if v := req.GetInt("per_page", 0); v > 0 {
		params.Set("per_page", strconv.Itoa(clampPerPage(v)))
	}
	body, _, err := g.githubCall(ctx, token, "/repos/"+owner+"/"+repo+"/actions/runs", params, "")
	if err != nil {
		return toolErrorf("github list workflow runs: %v", err), nil
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return toolErrorf("github decode: %v", err), nil
	}
	return jsonResult(out)
}

// requireOwnerRepoNumber centralises the owner/repo/number triple that
// nine of the GitHub tools need. Returns a tool-error result when any of
// the three is missing or non-positive.
func requireOwnerRepoNumber(req mcpgo.CallToolRequest) (string, string, int, *mcpgo.CallToolResult) {
	owner, err := req.RequireString("owner")
	if err != nil {
		return "", "", 0, toolErrorf("owner is required")
	}
	repo, err := req.RequireString("repo")
	if err != nil {
		return "", "", 0, toolErrorf("repo is required")
	}
	num := req.GetInt("number", 0)
	if num <= 0 {
		return "", "", 0, toolErrorf("number is required and must be positive")
	}
	return owner, repo, num, nil
}

// escapePath path-escapes each segment so file paths with spaces or
// unicode survive the URL build. Slashes between segments are preserved.
func escapePath(p string) string {
	parts := strings.Split(p, "/")
	for i, s := range parts {
		parts[i] = url.PathEscape(s)
	}
	return strings.Join(parts, "/")
}

func clampPerPage(n int) int {
	if n < 1 {
		return 1
	}
	if n > 100 {
		return 100
	}
	return n
}
