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
)

// registerGitHubWriteTools registers GitHub write tools. Each blocks on
// Gateway.Gate.AwaitApproval before hitting the API; without a wired
// emitter it fails closed (user_cancelled). Descriptions stay terse — the
// "gated" behavior is enforced server-side, no need to spend tokens
// reminding the model on every tools/list dump.
func (g *Gateway) registerGitHubWriteTools(srv *server.MCPServer) {
	owner := mcpgo.WithString("owner", mcpgo.Required())
	repo := mcpgo.WithString("repo", mcpgo.Required())
	num := mcpgo.WithNumber("number", mcpgo.Required())

	addTool(srv, "cb_github_post_review", "Post PR review.",
		[]mcpgo.ToolOption{
			owner, repo, num,
			mcpgo.WithString("event", mcpgo.Required(), mcpgo.Description("APPROVE|REQUEST_CHANGES|COMMENT.")),
			mcpgo.WithString("body", mcpgo.Description("Required for REQUEST_CHANGES/COMMENT.")),
		},
		g.githubPostReview,
	)

	addTool(srv, "cb_github_comment_issue", "Comment on issue/PR.",
		[]mcpgo.ToolOption{
			owner, repo, num,
			mcpgo.WithString("body", mcpgo.Required()),
		},
		g.githubCommentIssue,
	)

	addTool(srv, "cb_github_merge_pr", "Merge a PR.",
		[]mcpgo.ToolOption{
			owner, repo, num,
			mcpgo.WithString("method", mcpgo.Description("merge|squash|rebase.")),
			mcpgo.WithString("commit_title"),
		},
		g.githubMergePR,
	)

	addTool(srv, "cb_github_close_issue", "Close an issue.",
		[]mcpgo.ToolOption{
			owner, repo, num,
			mcpgo.WithString("reason", mcpgo.Description("completed|not_planned|reopened.")),
		},
		g.githubCloseIssue,
	)

	addTool(srv, "cb_github_create_issue", "Open an issue.",
		[]mcpgo.ToolOption{
			owner, repo,
			mcpgo.WithString("title", mcpgo.Required()),
			mcpgo.WithString("body"),
			mcpgo.WithString("labels", mcpgo.Description("CSV.")),
			mcpgo.WithString("assignees", mcpgo.Description("CSV logins.")),
		},
		g.githubCreateIssue,
	)

	addTool(srv, "cb_github_create_pr", "Open a PR.",
		[]mcpgo.ToolOption{
			owner, repo,
			mcpgo.WithString("title", mcpgo.Required()),
			mcpgo.WithString("head", mcpgo.Required(), mcpgo.Description("Source branch (or fork:branch).")),
			mcpgo.WithString("base", mcpgo.Required(), mcpgo.Description("Target branch.")),
			mcpgo.WithString("body"),
			mcpgo.WithBoolean("draft"),
			mcpgo.WithBoolean("maintainer_can_modify"),
		},
		g.githubCreatePR,
	)

	addTool(srv, "cb_github_update_issue", "Edit issue (title/body/labels/assignees/milestone). Use close_issue for state.",
		[]mcpgo.ToolOption{
			owner, repo, num,
			mcpgo.WithString("title"),
			mcpgo.WithString("body", mcpgo.Description("Empty string clears.")),
			mcpgo.WithString("labels", mcpgo.Description("CSV — REPLACES set. Use add_labels/remove_label for delta.")),
			mcpgo.WithString("assignees", mcpgo.Description("CSV — REPLACES set.")),
			mcpgo.WithNumber("milestone", mcpgo.Description("0 clears.")),
		},
		g.githubUpdateIssue,
	)

	addTool(srv, "cb_github_request_reviewers", "Request PR reviewers.",
		[]mcpgo.ToolOption{
			owner, repo, num,
			mcpgo.WithString("reviewers", mcpgo.Description("CSV logins.")),
			mcpgo.WithString("team_reviewers", mcpgo.Description("CSV team slugs.")),
		},
		g.githubRequestReviewers,
	)

	addTool(srv, "cb_github_add_labels", "Add labels (existing preserved).",
		[]mcpgo.ToolOption{
			owner, repo, num,
			mcpgo.WithString("labels", mcpgo.Required(), mcpgo.Description("CSV.")),
		},
		g.githubAddLabels,
	)

	addTool(srv, "cb_github_remove_label", "Remove one label.",
		[]mcpgo.ToolOption{
			owner, repo, num,
			mcpgo.WithString("label", mcpgo.Required()),
		},
		g.githubRemoveLabel,
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

func (g *Gateway) githubCreateIssue(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
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
	title, err := req.RequireString("title")
	if err != nil || strings.TrimSpace(title) == "" {
		return toolErrorf("title is required"), nil
	}
	body := req.GetString("body", "")
	labels := splitCSV(req.GetString("labels", ""))
	assignees := splitCSV(req.GetString("assignees", ""))

	payload := map[string]any{"title": title}
	if body != "" {
		payload["body"] = body
	}
	if len(labels) > 0 {
		payload["labels"] = labels
	}
	if len(assignees) > 0 {
		payload["assignees"] = assignees
	}

	args := map[string]any{"owner": owner, "repo": repo, "title": title}
	if body != "" {
		args["body"] = body
	}
	if len(labels) > 0 {
		args["labels"] = labels
	}
	if len(assignees) > 0 {
		args["assignees"] = assignees
	}
	summary := fmt.Sprintf("GitHub: open issue in %s/%s — %s", owner, repo, title)

	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_github_create_issue",
		Risk:    RiskLow,
		Origin:  OriginLLM,
		Summary: summary,
		Args:    args,
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			out, _, err := g.githubPostJSON(ctx, token, "/repos/"+owner+"/"+repo+"/issues", payload)
			if err != nil {
				return toolErrorf("github create issue: %v", err), nil
			}
			var v map[string]any
			if err := json.Unmarshal(out, &v); err != nil {
				return toolErrorf("github decode: %v", err), nil
			}
			return jsonResult(v)
		},
	})
}

func (g *Gateway) githubCreatePR(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
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
	title, err := req.RequireString("title")
	if err != nil || strings.TrimSpace(title) == "" {
		return toolErrorf("title is required"), nil
	}
	head, err := req.RequireString("head")
	if err != nil || strings.TrimSpace(head) == "" {
		return toolErrorf("head is required"), nil
	}
	base, err := req.RequireString("base")
	if err != nil || strings.TrimSpace(base) == "" {
		return toolErrorf("base is required"), nil
	}
	body := req.GetString("body", "")
	draft := req.GetBool("draft", false)
	// Default to true to match the GitHub UI default. Only forwarded when
	// the head/base spans forks; ignored otherwise.
	maintainerCanModify := req.GetBool("maintainer_can_modify", true)

	payload := map[string]any{
		"title":                 title,
		"head":                  head,
		"base":                  base,
		"draft":                 draft,
		"maintainer_can_modify": maintainerCanModify,
	}
	if body != "" {
		payload["body"] = body
	}

	args := map[string]any{
		"owner": owner, "repo": repo,
		"title": title, "head": head, "base": base,
		"draft": draft,
	}
	if body != "" {
		args["body"] = body
	}
	risk := RiskMedium
	if draft {
		risk = RiskLow
	}
	summary := fmt.Sprintf("GitHub: open PR %s/%s %s ← %s — %s", owner, repo, base, head, title)

	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_github_create_pr",
		Risk:    risk,
		Origin:  OriginLLM,
		Summary: summary,
		Args:    args,
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			out, _, err := g.githubPostJSON(ctx, token, "/repos/"+owner+"/"+repo+"/pulls", payload)
			if err != nil {
				return toolErrorf("github create pr: %v", err), nil
			}
			var v map[string]any
			if err := json.Unmarshal(out, &v); err != nil {
				return toolErrorf("github decode: %v", err), nil
			}
			return jsonResult(v)
		},
	})
}

func (g *Gateway) githubUpdateIssue(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	owner, repo, num, errRes := requireOwnerRepoNumber(req)
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
	if v, ok := supplied["body"]; ok {
		s, _ := v.(string)
		payload["body"] = s
	}
	if v, ok := supplied["labels"]; ok {
		if s, _ := v.(string); true {
			payload["labels"] = splitCSV(s)
		}
	}
	if v, ok := supplied["assignees"]; ok {
		if s, _ := v.(string); true {
			payload["assignees"] = splitCSV(s)
		}
	}
	if _, ok := supplied["milestone"]; ok {
		ms := req.GetInt("milestone", 0)
		if ms <= 0 {
			payload["milestone"] = nil
		} else {
			payload["milestone"] = ms
		}
	}
	if len(payload) == 0 {
		return toolErrorf("at least one of title, body, labels, assignees, milestone must be provided"), nil
	}

	args := map[string]any{"owner": owner, "repo": repo, "number": num}
	for k, v := range payload {
		args[k] = v
	}
	summary := fmt.Sprintf("GitHub: edit %s/%s#%d (%d field%s)", owner, repo, num, len(payload), plural(len(payload)))
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_github_update_issue",
		Risk:    RiskLow,
		Origin:  OriginLLM,
		Summary: summary,
		Args:    args,
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			out, _, err := g.githubPatchJSON(ctx, token, fmt.Sprintf("/repos/%s/%s/issues/%d", owner, repo, num), payload)
			if err != nil {
				return toolErrorf("github update issue: %v", err), nil
			}
			var v map[string]any
			if err := json.Unmarshal(out, &v); err != nil {
				return toolErrorf("github decode: %v", err), nil
			}
			return jsonResult(v)
		},
	})
}

func (g *Gateway) githubRequestReviewers(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	owner, repo, num, errRes := requireOwnerRepoNumber(req)
	if errRes != nil {
		return errRes, nil
	}
	reviewers := splitCSV(req.GetString("reviewers", ""))
	teamReviewers := splitCSV(req.GetString("team_reviewers", ""))
	if len(reviewers) == 0 && len(teamReviewers) == 0 {
		return toolErrorf("at least one of reviewers or team_reviewers is required"), nil
	}

	payload := map[string]any{}
	if len(reviewers) > 0 {
		payload["reviewers"] = reviewers
	}
	if len(teamReviewers) > 0 {
		payload["team_reviewers"] = teamReviewers
	}

	args := map[string]any{"owner": owner, "repo": repo, "number": num}
	if len(reviewers) > 0 {
		args["reviewers"] = reviewers
	}
	if len(teamReviewers) > 0 {
		args["team_reviewers"] = teamReviewers
	}
	summary := fmt.Sprintf("GitHub: request %d reviewer%s on %s/%s#%d", len(reviewers)+len(teamReviewers), plural(len(reviewers)+len(teamReviewers)), owner, repo, num)
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_github_request_reviewers",
		Risk:    RiskLow,
		Origin:  OriginLLM,
		Summary: summary,
		Args:    args,
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			out, _, err := g.githubPostJSON(ctx, token, fmt.Sprintf("/repos/%s/%s/pulls/%d/requested_reviewers", owner, repo, num), payload)
			if err != nil {
				return toolErrorf("github request reviewers: %v", err), nil
			}
			var v map[string]any
			if err := json.Unmarshal(out, &v); err != nil {
				return toolErrorf("github decode: %v", err), nil
			}
			return jsonResult(v)
		},
	})
}

func (g *Gateway) githubAddLabels(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	owner, repo, num, errRes := requireOwnerRepoNumber(req)
	if errRes != nil {
		return errRes, nil
	}
	labels := splitCSV(req.GetString("labels", ""))
	if len(labels) == 0 {
		return toolErrorf("labels is required"), nil
	}

	args := map[string]any{"owner": owner, "repo": repo, "number": num, "labels": labels}
	summary := fmt.Sprintf("GitHub: add labels [%s] to %s/%s#%d", strings.Join(labels, ","), owner, repo, num)
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_github_add_labels",
		Risk:    RiskLow,
		Origin:  OriginLLM,
		Summary: summary,
		Args:    args,
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			out, _, err := g.githubPostJSON(ctx, token, fmt.Sprintf("/repos/%s/%s/issues/%d/labels", owner, repo, num), map[string]any{"labels": labels})
			if err != nil {
				return toolErrorf("github add labels: %v", err), nil
			}
			var v []map[string]any
			if err := json.Unmarshal(out, &v); err != nil {
				return toolErrorf("github decode: %v", err), nil
			}
			return jsonResult(v)
		},
	})
}

func (g *Gateway) githubRemoveLabel(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, token, errRes := g.githubResolveAndToken(ctx)
	if errRes != nil {
		return errRes, nil
	}
	owner, repo, num, errRes := requireOwnerRepoNumber(req)
	if errRes != nil {
		return errRes, nil
	}
	label, err := req.RequireString("label")
	if err != nil || strings.TrimSpace(label) == "" {
		return toolErrorf("label is required"), nil
	}

	args := map[string]any{"owner": owner, "repo": repo, "number": num, "label": label}
	summary := fmt.Sprintf("GitHub: remove label %q from %s/%s#%d", label, owner, repo, num)
	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_github_remove_label",
		Risk:    RiskLow,
		Origin:  OriginLLM,
		Summary: summary,
		Args:    args,
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			out, _, err := g.githubDeleteNoBody(ctx, token, fmt.Sprintf("/repos/%s/%s/issues/%d/labels/%s", owner, repo, num, url.PathEscape(label)))
			if err != nil {
				return toolErrorf("github remove label: %v", err), nil
			}
			var v []map[string]any
			if err := json.Unmarshal(out, &v); err != nil {
				// 200 returns remaining labels; some race conditions return 404
				// with an empty body — surface as the raw payload instead of
				// trying to decode it as a list.
				return jsonResult(map[string]any{"raw": string(out)})
			}
			return jsonResult(v)
		},
	})
}

func splitCSV(s string) []string {
	out := []string{}
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
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

// githubDeleteNoBody issues a DELETE with no request body — used by the
// label-removal endpoint which accepts an empty body and returns the
// remaining label list as JSON.
func (g *Gateway) githubDeleteNoBody(ctx context.Context, token, path string) ([]byte, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, githubAPIEndpoint()+path, nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
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
