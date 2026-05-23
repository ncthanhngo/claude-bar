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
)

// registerGitHubWriteTools registers the 4 write-capable GitHub tools. Each
// blocks on Gateway.Gate.AwaitApproval before hitting GitHub; without a wired
// emitter it fails closed (user_cancelled) and never reaches the API.
func (g *Gateway) registerGitHubWriteTools(srv *server.MCPServer) {
	addTool(srv, "cb_github_post_review",
		"Post a pull-request review (approve / request_changes / comment). Gated.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("owner", mcpgo.Required(), mcpgo.Description("Repo owner.")),
			mcpgo.WithString("repo", mcpgo.Required(), mcpgo.Description("Repository name.")),
			mcpgo.WithNumber("number", mcpgo.Required(), mcpgo.Description("Pull request number.")),
			mcpgo.WithString("event", mcpgo.Required(), mcpgo.Description("APPROVE | REQUEST_CHANGES | COMMENT.")),
			mcpgo.WithString("body", mcpgo.Description("Review body. Required for REQUEST_CHANGES and COMMENT.")),
		},
		g.githubPostReview,
	)

	addTool(srv, "cb_github_comment_issue",
		"Add a comment to an issue or pull request. Gated.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("owner", mcpgo.Required(), mcpgo.Description("Repo owner.")),
			mcpgo.WithString("repo", mcpgo.Required(), mcpgo.Description("Repository name.")),
			mcpgo.WithNumber("number", mcpgo.Required(), mcpgo.Description("Issue or PR number.")),
			mcpgo.WithString("body", mcpgo.Required(), mcpgo.Description("Comment body (markdown).")),
		},
		g.githubCommentIssue,
	)

	addTool(srv, "cb_github_merge_pr",
		"Merge a pull request. Destructive — surfaces a modal gate.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("owner", mcpgo.Required(), mcpgo.Description("Repo owner.")),
			mcpgo.WithString("repo", mcpgo.Required(), mcpgo.Description("Repository name.")),
			mcpgo.WithNumber("number", mcpgo.Required(), mcpgo.Description("Pull request number.")),
			mcpgo.WithString("method", mcpgo.Description("merge | squash | rebase. Default merge.")),
			mcpgo.WithString("commit_title", mcpgo.Description("Optional commit title.")),
		},
		g.githubMergePR,
	)

	addTool(srv, "cb_github_close_issue",
		"Close an issue. Destructive — surfaces a modal gate.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("owner", mcpgo.Required(), mcpgo.Description("Repo owner.")),
			mcpgo.WithString("repo", mcpgo.Required(), mcpgo.Description("Repository name.")),
			mcpgo.WithNumber("number", mcpgo.Required(), mcpgo.Description("Issue number.")),
			mcpgo.WithString("reason", mcpgo.Description("completed | not_planned | reopened. Default completed.")),
		},
		g.githubCloseIssue,
	)
}

func (g *Gateway) githubPostReview(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, token, errRes := g.githubResolveAndToken(ctx)
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
	number := req.GetInt("number", 0)
	if number <= 0 {
		return toolErrorf("number is required"), nil
	}
	event := strings.ToUpper(strings.TrimSpace(req.GetString("event", "")))
	switch event {
	case "APPROVE", "REQUEST_CHANGES", "COMMENT":
	default:
		return toolErrorf("event must be APPROVE | REQUEST_CHANGES | COMMENT"), nil
	}
	body := req.GetString("body", "")
	if (event == "REQUEST_CHANGES" || event == "COMMENT") && strings.TrimSpace(body) == "" {
		return toolErrorf("body is required for %s", event), nil
	}

	risk := RiskLow
	if event == "REQUEST_CHANGES" {
		risk = RiskMedium
	}
	args := map[string]any{"owner": owner, "repo": repo, "number": number, "event": event, "body": body}
	summary := fmt.Sprintf("GitHub: %s PR %s/%s#%d", event, owner, repo, number)

	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_github_post_review",
		Risk:    risk,
		Origin:  OriginLLM,
		Summary: summary,
		Args:    args,
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			path := fmt.Sprintf("/repos/%s/%s/pulls/%d/reviews", owner, repo, number)
			payload := map[string]any{"event": event}
			if body != "" {
				payload["body"] = body
			}
			body, _, err := g.githubPostJSON(ctx, token, path, payload)
			if err != nil {
				return toolErrorf("github post review: %v", err), nil
			}
			var out map[string]any
			if err := json.Unmarshal(body, &out); err != nil {
				return toolErrorf("github decode: %v", err), nil
			}
			return jsonResult(out)
		},
	})
}

func (g *Gateway) githubCommentIssue(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, token, errRes := g.githubResolveAndToken(ctx)
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
	number := req.GetInt("number", 0)
	if number <= 0 {
		return toolErrorf("number is required"), nil
	}
	body, err := req.RequireString("body")
	if err != nil || strings.TrimSpace(body) == "" {
		return toolErrorf("body is required"), nil
	}

	args := map[string]any{"owner": owner, "repo": repo, "number": number, "body": body}
	summary := fmt.Sprintf("GitHub: comment on %s/%s#%d", owner, repo, number)
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_github_comment_issue",
		Risk:    RiskLow,
		Origin:  OriginLLM,
		Summary: summary,
		Args:    args,
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			path := fmt.Sprintf("/repos/%s/%s/issues/%d/comments", owner, repo, number)
			out, _, err := g.githubPostJSON(ctx, token, path, map[string]any{"body": body})
			if err != nil {
				return toolErrorf("github comment: %v", err), nil
			}
			var v map[string]any
			if err := json.Unmarshal(out, &v); err != nil {
				return toolErrorf("github decode: %v", err), nil
			}
			return jsonResult(v)
		},
	})
}

func (g *Gateway) githubMergePR(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, token, errRes := g.githubResolveAndToken(ctx)
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
	number := req.GetInt("number", 0)
	if number <= 0 {
		return toolErrorf("number is required"), nil
	}
	method := strings.TrimSpace(req.GetString("method", "merge"))
	switch method {
	case "merge", "squash", "rebase":
	default:
		return toolErrorf("method must be merge | squash | rebase"), nil
	}
	title := strings.TrimSpace(req.GetString("commit_title", ""))

	args := map[string]any{"owner": owner, "repo": repo, "number": number, "method": method}
	if title != "" {
		args["commit_title"] = title
	}
	summary := fmt.Sprintf("GitHub: MERGE %s PR %s/%s#%d", method, owner, repo, number)
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_github_merge_pr",
		Risk:    RiskDestructive,
		Origin:  OriginLLM,
		Summary: summary,
		Args:    args,
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			path := fmt.Sprintf("/repos/%s/%s/pulls/%d/merge", owner, repo, number)
			payload := map[string]any{"merge_method": method}
			if title != "" {
				payload["commit_title"] = title
			}
			out, _, err := g.githubPutJSON(ctx, token, path, payload)
			if err != nil {
				return toolErrorf("github merge: %v", err), nil
			}
			var v map[string]any
			if err := json.Unmarshal(out, &v); err != nil {
				return toolErrorf("github decode: %v", err), nil
			}
			return jsonResult(v)
		},
	})
}

func (g *Gateway) githubCloseIssue(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, token, errRes := g.githubResolveAndToken(ctx)
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
	number := req.GetInt("number", 0)
	if number <= 0 {
		return toolErrorf("number is required"), nil
	}
	reason := strings.TrimSpace(req.GetString("reason", "completed"))
	switch reason {
	case "completed", "not_planned", "reopened":
	default:
		return toolErrorf("reason must be completed | not_planned | reopened"), nil
	}

	args := map[string]any{"owner": owner, "repo": repo, "number": number, "reason": reason}
	summary := fmt.Sprintf("GitHub: CLOSE %s/%s#%d (%s)", owner, repo, number, reason)
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_github_close_issue",
		Risk:    RiskDestructive,
		Origin:  OriginLLM,
		Summary: summary,
		Args:    args,
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			path := fmt.Sprintf("/repos/%s/%s/issues/%d", owner, repo, number)
			payload := map[string]any{"state": "closed", "state_reason": reason}
			if reason == "reopened" {
				payload["state"] = "open"
				delete(payload, "state_reason")
			}
			out, _, err := g.githubPatchJSON(ctx, token, path, payload)
			if err != nil {
				return toolErrorf("github close: %v", err), nil
			}
			var v map[string]any
			if err := json.Unmarshal(out, &v); err != nil {
				return toolErrorf("github decode: %v", err), nil
			}
			return jsonResult(v)
		},
	})
}

// HTTP helpers for the JSON-body methods.

func (g *Gateway) githubPostJSON(ctx context.Context, token, path string, payload any) ([]byte, int, error) {
	return g.githubBodyJSON(ctx, http.MethodPost, token, path, payload)
}

func (g *Gateway) githubPutJSON(ctx context.Context, token, path string, payload any) ([]byte, int, error) {
	return g.githubBodyJSON(ctx, http.MethodPut, token, path, payload)
}

func (g *Gateway) githubPatchJSON(ctx context.Context, token, path string, payload any) ([]byte, int, error) {
	return g.githubBodyJSON(ctx, http.MethodPatch, token, path, payload)
}

func (g *Gateway) githubBodyJSON(ctx context.Context, method, token, path string, payload any) ([]byte, int, error) {
	buf, err := json.Marshal(payload)
	if err != nil {
		return nil, 0, fmt.Errorf("encode body: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, method, githubAPIEndpoint()+path, bytes.NewReader(buf))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("User-Agent", g.UserAgent)

	resp, err := g.HTTP.Do(req)
	if err != nil {
		return nil, 0, fmt.Errorf("github http: %w", err)
	}
	defer resp.Body.Close()
	out, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, resp.StatusCode, fmt.Errorf("github read: %w", err)
	}
	if resp.StatusCode/100 != 2 {
		return out, resp.StatusCode, fmt.Errorf("github http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(out))))
	}
	return out, resp.StatusCode, nil
}
