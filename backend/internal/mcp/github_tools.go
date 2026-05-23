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

// registerGitHubTools registers the GitHub read tools. Write tools (Phase 2
// continued) plug in here alongside once the widget gate UI lands.
func (g *Gateway) registerGitHubTools(srv *server.MCPServer) {
	addTool(srv, "cb_github_list_prs",
		"List pull requests in a GitHub repository. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("owner", mcpgo.Required(), mcpgo.Description("Repo owner (user or organisation).")),
			mcpgo.WithString("repo", mcpgo.Required(), mcpgo.Description("Repository name.")),
			mcpgo.WithString("state", mcpgo.Description("open | closed | all. Default open.")),
			mcpgo.WithString("sort", mcpgo.Description("created | updated | popularity | long-running. Default created.")),
			mcpgo.WithNumber("per_page", mcpgo.Description("1–100. Default 30.")),
		},
		g.githubListPRs,
	)

	addTool(srv, "cb_github_get_pr",
		"Get one pull request including head/base, mergeable state, and labels. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("owner", mcpgo.Required(), mcpgo.Description("Repo owner.")),
			mcpgo.WithString("repo", mcpgo.Required(), mcpgo.Description("Repository name.")),
			mcpgo.WithNumber("number", mcpgo.Required(), mcpgo.Description("Pull request number.")),
		},
		g.githubGetPR,
	)

	addTool(srv, "cb_github_get_pr_diff",
		"Get the unified diff for a pull request as text. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("owner", mcpgo.Required(), mcpgo.Description("Repo owner.")),
			mcpgo.WithString("repo", mcpgo.Required(), mcpgo.Description("Repository name.")),
			mcpgo.WithNumber("number", mcpgo.Required(), mcpgo.Description("Pull request number.")),
		},
		g.githubGetPRDiff,
	)

	addTool(srv, "cb_github_list_issues",
		"List issues in a GitHub repository. Read-only. Excludes pull requests.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("owner", mcpgo.Required(), mcpgo.Description("Repo owner.")),
			mcpgo.WithString("repo", mcpgo.Required(), mcpgo.Description("Repository name.")),
			mcpgo.WithString("state", mcpgo.Description("open | closed | all. Default open.")),
			mcpgo.WithString("labels", mcpgo.Description("Comma-separated label names.")),
			mcpgo.WithNumber("per_page", mcpgo.Description("1–100. Default 30.")),
		},
		g.githubListIssues,
	)

	addTool(srv, "cb_github_search_code",
		"Search code across repositories visible to the authenticated user. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("query", mcpgo.Required(), mcpgo.Description("GitHub code-search query (e.g. `repo:owner/name path:src foo`).")),
			mcpgo.WithNumber("per_page", mcpgo.Description("1–100. Default 30.")),
		},
		g.githubSearchCode,
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

func clampPerPage(n int) int {
	if n < 1 {
		return 1
	}
	if n > 100 {
		return 100
	}
	return n
}
