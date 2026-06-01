package mcp

import "github.com/soi/claude-swap-widget/backend/internal/domain"

// ToolPriority sorts tools in the widget's tool-toggle UI. Essential
// tools surface at the top of each connector's tool list, common ones
// in the middle, advanced (rarely-used, write-heavy, or destructive)
// at the bottom under a divider. Priority is a UI hint only — the
// gateway enables/disables tools strictly by ID, never by priority.
type ToolPriority int

const (
	ToolPriorityEssential ToolPriority = 0
	ToolPriorityCommon    ToolPriority = 1
	ToolPriorityAdvanced  ToolPriority = 2
)

// ToolMeta is one tool's user-facing metadata. The catalog is the single
// source of truth that both the gateway (filtering tools/list) and the
// widget (rendering the toggle UI) consume. Adding a new MCP tool means
// adding one ToolMeta here plus the addTool registration in the
// service's *_tools.go file — keeping the two in lock-step ensures the
// UI never shows toggles for tools the gateway can't actually serve and
// vice versa.
type ToolMeta struct {
	ID          string
	Service     domain.MCPService
	Label       string
	Description string
	Category    string
	Priority    ToolPriority
}

// AllTools is the curated catalog of every tool the gateway ships. Order
// within a service drives the in-category order in the UI; cross-service
// order is irrelevant because the widget groups by Service first.
var AllTools = []ToolMeta{
	// ────────────────────────────── Slack
	{ID: "cb_slack_list_channels", Service: domain.MCPServiceSlack, Label: "List channels", Description: "Enumerate channels visible to the authenticated user.", Category: "Channels", Priority: ToolPriorityEssential},
	{ID: "cb_slack_list_users", Service: domain.MCPServiceSlack, Label: "List users", Description: "Roster of workspace members.", Category: "People", Priority: ToolPriorityCommon},
	{ID: "cb_slack_get_user", Service: domain.MCPServiceSlack, Label: "Get user", Description: "Profile + status for one user.", Category: "People", Priority: ToolPriorityCommon},
	{ID: "cb_slack_search_messages", Service: domain.MCPServiceSlack, Label: "Search messages", Description: "Full-text search across channels the user can see.", Category: "Messages", Priority: ToolPriorityEssential},
	{ID: "cb_slack_get_channel_history", Service: domain.MCPServiceSlack, Label: "Channel history", Description: "Recent messages in one channel.", Category: "Messages", Priority: ToolPriorityCommon},
	{ID: "cb_slack_get_thread", Service: domain.MCPServiceSlack, Label: "Get thread", Description: "All replies under one parent message.", Category: "Messages", Priority: ToolPriorityCommon},
	{ID: "cb_slack_get_permalink", Service: domain.MCPServiceSlack, Label: "Get permalink", Description: "Stable URL for a message — useful for citations.", Category: "Messages", Priority: ToolPriorityCommon},
	{ID: "cb_slack_post_message", Service: domain.MCPServiceSlack, Label: "Post message", Description: "Send a new message to a channel or DM. Gated.", Category: "Writes", Priority: ToolPriorityAdvanced},
	{ID: "cb_slack_reply_thread", Service: domain.MCPServiceSlack, Label: "Reply in thread", Description: "Append a message to an existing thread. Gated.", Category: "Writes", Priority: ToolPriorityAdvanced},

	// ────────────────────────────── ClickUp
	{ID: "cb_clickup_list_workspaces", Service: domain.MCPServiceClickUp, Label: "List workspaces", Description: "Top-level workspace roster — needed to scope every other call.", Category: "Workspaces", Priority: ToolPriorityEssential},
	{ID: "cb_clickup_list_spaces", Service: domain.MCPServiceClickUp, Label: "List spaces", Description: "Spaces inside a workspace.", Category: "Workspaces", Priority: ToolPriorityCommon},
	{ID: "cb_clickup_list_folders", Service: domain.MCPServiceClickUp, Label: "List folders", Description: "Folders inside a space.", Category: "Workspaces", Priority: ToolPriorityCommon},
	{ID: "cb_clickup_list_lists", Service: domain.MCPServiceClickUp, Label: "List lists", Description: "Lists inside a folder.", Category: "Workspaces", Priority: ToolPriorityCommon},
	{ID: "cb_clickup_list_members", Service: domain.MCPServiceClickUp, Label: "List members", Description: "Members of a workspace.", Category: "People", Priority: ToolPriorityCommon},
	{ID: "cb_clickup_list_tasks", Service: domain.MCPServiceClickUp, Label: "List tasks", Description: "Tasks in a list with optional status/assignee filters.", Category: "Tasks", Priority: ToolPriorityEssential},
	{ID: "cb_clickup_get_task", Service: domain.MCPServiceClickUp, Label: "Get task", Description: "Full detail for one task — description, comments, fields.", Category: "Tasks", Priority: ToolPriorityEssential},
	{ID: "cb_clickup_get_doc", Service: domain.MCPServiceClickUp, Label: "Read Doc", Description: "Markdown content of a ClickUp Doc (single page or whole doc) from a doc URL or workspace_id + doc_id.", Category: "Docs", Priority: ToolPriorityCommon},
	{ID: "cb_clickup_search_tasks", Service: domain.MCPServiceClickUp, Label: "Search tasks", Description: "Full-text task search across a workspace.", Category: "Tasks", Priority: ToolPriorityCommon},
	{ID: "cb_clickup_list_comments", Service: domain.MCPServiceClickUp, Label: "List comments", Description: "Comments on one task.", Category: "Comments", Priority: ToolPriorityCommon},
	{ID: "cb_clickup_create_task", Service: domain.MCPServiceClickUp, Label: "Create task", Description: "Open a new task in a list. Gated.", Category: "Writes", Priority: ToolPriorityCommon},
	{ID: "cb_clickup_update_task", Service: domain.MCPServiceClickUp, Label: "Update task", Description: "Edit title / description / fields. Gated.", Category: "Writes", Priority: ToolPriorityCommon},
	{ID: "cb_clickup_update_task_status", Service: domain.MCPServiceClickUp, Label: "Change task status", Description: "Move a task to a new status. Gated.", Category: "Writes", Priority: ToolPriorityCommon},
	{ID: "cb_clickup_assign", Service: domain.MCPServiceClickUp, Label: "Assign task", Description: "Set/replace task assignees. Gated.", Category: "Writes", Priority: ToolPriorityAdvanced},
	{ID: "cb_clickup_add_comment", Service: domain.MCPServiceClickUp, Label: "Add comment", Description: "Post a comment on a task. Gated.", Category: "Writes", Priority: ToolPriorityCommon},
	{ID: "cb_clickup_capture", Service: domain.MCPServiceClickUp, Label: "Quick capture", Description: "One-shot task creation from a single natural-language line. Gated.", Category: "Writes", Priority: ToolPriorityAdvanced},

	// ────────────────────────────── Google Drive
	{ID: "cb_gdrive_search_files", Service: domain.MCPServiceGDrive, Label: "Search files", Description: "Find files by name / type / owner.", Category: "Drive", Priority: ToolPriorityEssential},
	{ID: "cb_gdrive_get_file_metadata", Service: domain.MCPServiceGDrive, Label: "File metadata", Description: "Owner, mime type, modified time for one file.", Category: "Drive", Priority: ToolPriorityCommon},
	{ID: "cb_gdrive_get_doc_text", Service: domain.MCPServiceGDrive, Label: "Read Doc text", Description: "Plain-text content of a Google Doc.", Category: "Drive", Priority: ToolPriorityEssential},
	{ID: "cb_gdrive_download_file", Service: domain.MCPServiceGDrive, Label: "Download file", Description: "Fetch the raw bytes of a Drive file.", Category: "Drive", Priority: ToolPriorityCommon},
	{ID: "cb_gdrive_list_folder", Service: domain.MCPServiceGDrive, Label: "List folder", Description: "Direct children of one folder.", Category: "Drive", Priority: ToolPriorityCommon},
	{ID: "cb_gdrive_share_file", Service: domain.MCPServiceGDrive, Label: "Share file", Description: "Grant reader/commenter/writer access to one Drive file. Gated.", Category: "Drive", Priority: ToolPriorityAdvanced},

	// ────────────────────────────── Google Sheets
	{ID: "cb_gsheets_create_spreadsheet", Service: domain.MCPServiceGDrive, Label: "Create spreadsheet", Description: "Make a new empty Google Sheet under the active account. Gated.", Category: "Writes", Priority: ToolPriorityCommon},
	{ID: "cb_gsheets_create_from_csv", Service: domain.MCPServiceGDrive, Label: "Create sheet from CSV", Description: "Create a new Sheet and populate cells from CSV text in one call. Gated.", Category: "Writes", Priority: ToolPriorityCommon},
	{ID: "cb_gsheets_update_values", Service: domain.MCPServiceGDrive, Label: "Update cells", Description: "Overwrite a rectangular range of cells in an existing Sheet. Gated.", Category: "Writes", Priority: ToolPriorityAdvanced},
	{ID: "cb_gsheets_append_values", Service: domain.MCPServiceGDrive, Label: "Append rows", Description: "Append rows to the end of a Sheet table. Gated.", Category: "Writes", Priority: ToolPriorityAdvanced},

	// ────────────────────────────── Google Calendar
	{ID: "cb_gcal_list_calendars", Service: domain.MCPServiceGDrive, Label: "List calendars", Description: "Calendars the user has access to.", Category: "Calendar", Priority: ToolPriorityCommon},
	{ID: "cb_gcal_list_events", Service: domain.MCPServiceGDrive, Label: "List events", Description: "Events in a time window.", Category: "Calendar", Priority: ToolPriorityEssential},
	{ID: "cb_gcal_get_event", Service: domain.MCPServiceGDrive, Label: "Get event", Description: "Full detail for one event.", Category: "Calendar", Priority: ToolPriorityCommon},
	{ID: "cb_gcal_get_free_busy", Service: domain.MCPServiceGDrive, Label: "Free / busy", Description: "Availability for one or more calendars in a window.", Category: "Calendar", Priority: ToolPriorityCommon},

	// ────────────────────────────── Gmail
	{ID: "cb_gmail_search_messages", Service: domain.MCPServiceGDrive, Label: "Search mail", Description: "Gmail-syntax search (`from:`, `is:unread`, …).", Category: "Gmail", Priority: ToolPriorityEssential},
	{ID: "cb_gmail_get_message", Service: domain.MCPServiceGDrive, Label: "Get message", Description: "Headers + body for one message.", Category: "Gmail", Priority: ToolPriorityCommon},
	{ID: "cb_gmail_get_thread", Service: domain.MCPServiceGDrive, Label: "Get thread", Description: "All messages in a thread.", Category: "Gmail", Priority: ToolPriorityCommon},
	{ID: "cb_gmail_list_labels", Service: domain.MCPServiceGDrive, Label: "List labels", Description: "Gmail label catalog including system labels.", Category: "Gmail", Priority: ToolPriorityAdvanced},

	// ────────────────────────────── GitHub
	{ID: "cb_github_list_prs", Service: domain.MCPServiceGitHub, Label: "List PRs", Description: "Pull requests in a repo with state / sort filters.", Category: "PRs", Priority: ToolPriorityEssential},
	{ID: "cb_github_get_pr", Service: domain.MCPServiceGitHub, Label: "Get PR", Description: "Full detail for one PR — mergeable state, labels.", Category: "PRs", Priority: ToolPriorityEssential},
	{ID: "cb_github_get_pr_diff", Service: domain.MCPServiceGitHub, Label: "PR diff", Description: "Unified diff text for a PR.", Category: "PRs", Priority: ToolPriorityEssential},
	{ID: "cb_github_list_pr_files", Service: domain.MCPServiceGitHub, Label: "PR files", Description: "Files changed with patch hunks.", Category: "PRs", Priority: ToolPriorityCommon},
	{ID: "cb_github_list_pr_commits", Service: domain.MCPServiceGitHub, Label: "PR commits", Description: "Commits included in a PR.", Category: "PRs", Priority: ToolPriorityCommon},
	{ID: "cb_github_list_pr_reviews", Service: domain.MCPServiceGitHub, Label: "PR reviews", Description: "Submitted reviews on a PR.", Category: "PRs", Priority: ToolPriorityCommon},
	{ID: "cb_github_list_pr_review_comments", Service: domain.MCPServiceGitHub, Label: "PR review comments", Description: "Inline review comments anchored to diff lines.", Category: "PRs", Priority: ToolPriorityCommon},
	{ID: "cb_github_list_issues", Service: domain.MCPServiceGitHub, Label: "List issues", Description: "Issues in a repo (excludes PRs).", Category: "Issues", Priority: ToolPriorityEssential},
	{ID: "cb_github_get_issue", Service: domain.MCPServiceGitHub, Label: "Get issue", Description: "One issue with labels and assignees.", Category: "Issues", Priority: ToolPriorityEssential},
	{ID: "cb_github_list_issue_comments", Service: domain.MCPServiceGitHub, Label: "Issue comments", Description: "Comments on an issue or PR.", Category: "Issues", Priority: ToolPriorityCommon},
	{ID: "cb_github_search_code", Service: domain.MCPServiceGitHub, Label: "Search code", Description: "Code search across visible repos.", Category: "Search", Priority: ToolPriorityCommon},
	{ID: "cb_github_search_issues", Service: domain.MCPServiceGitHub, Label: "Search issues / PRs", Description: "Issue/PR search across GitHub.", Category: "Search", Priority: ToolPriorityCommon},
	{ID: "cb_github_get_file_content", Service: domain.MCPServiceGitHub, Label: "Read file", Description: "Raw file contents at a ref.", Category: "Repo", Priority: ToolPriorityEssential},
	{ID: "cb_github_list_commits", Service: domain.MCPServiceGitHub, Label: "List commits", Description: "Commits on a branch or path.", Category: "Repo", Priority: ToolPriorityCommon},
	{ID: "cb_github_get_commit", Service: domain.MCPServiceGitHub, Label: "Get commit", Description: "Commit detail with patches.", Category: "Repo", Priority: ToolPriorityCommon},
	{ID: "cb_github_list_branches", Service: domain.MCPServiceGitHub, Label: "List branches", Description: "Repo branches.", Category: "Repo", Priority: ToolPriorityCommon},
	{ID: "cb_github_list_check_runs", Service: domain.MCPServiceGitHub, Label: "Check runs", Description: "CI check runs at a ref.", Category: "CI", Priority: ToolPriorityCommon},
	{ID: "cb_github_list_workflow_runs", Service: domain.MCPServiceGitHub, Label: "Workflow runs", Description: "Actions workflow run history.", Category: "CI", Priority: ToolPriorityCommon},
	{ID: "cb_github_post_review", Service: domain.MCPServiceGitHub, Label: "Post PR review", Description: "Approve / request changes / comment on a PR. Gated.", Category: "Writes", Priority: ToolPriorityCommon},
	{ID: "cb_github_comment_issue", Service: domain.MCPServiceGitHub, Label: "Comment on issue/PR", Description: "Add a comment. Gated.", Category: "Writes", Priority: ToolPriorityCommon},
	{ID: "cb_github_create_issue", Service: domain.MCPServiceGitHub, Label: "Open issue", Description: "Create a new issue. Gated.", Category: "Writes", Priority: ToolPriorityCommon},
	{ID: "cb_github_create_pr", Service: domain.MCPServiceGitHub, Label: "Open PR", Description: "Create a new pull request. Gated.", Category: "Writes", Priority: ToolPriorityCommon},
	{ID: "cb_github_update_issue", Service: domain.MCPServiceGitHub, Label: "Edit issue", Description: "Modify title / body / labels / assignees / milestone. Gated.", Category: "Writes", Priority: ToolPriorityAdvanced},
	{ID: "cb_github_close_issue", Service: domain.MCPServiceGitHub, Label: "Close issue", Description: "Close or reopen an issue. Gated.", Category: "Writes", Priority: ToolPriorityAdvanced},
	{ID: "cb_github_merge_pr", Service: domain.MCPServiceGitHub, Label: "Merge PR", Description: "Merge a pull request. Destructive — surfaces a modal gate.", Category: "Writes", Priority: ToolPriorityAdvanced},
	{ID: "cb_github_request_reviewers", Service: domain.MCPServiceGitHub, Label: "Request reviewers", Description: "Ask users or teams to review a PR. Gated.", Category: "Writes", Priority: ToolPriorityAdvanced},
	{ID: "cb_github_add_labels", Service: domain.MCPServiceGitHub, Label: "Add labels", Description: "Add labels to an issue or PR. Gated.", Category: "Writes", Priority: ToolPriorityAdvanced},
	{ID: "cb_github_remove_label", Service: domain.MCPServiceGitHub, Label: "Remove label", Description: "Remove a single label. Gated.", Category: "Writes", Priority: ToolPriorityAdvanced},

	// ────────────────────────────── GitLab
	{ID: "cb_gitlab_list_mrs", Service: domain.MCPServiceGitLab, Label: "List MRs", Description: "Merge requests in a project with state filters.", Category: "MRs", Priority: ToolPriorityEssential},
	{ID: "cb_gitlab_get_mr", Service: domain.MCPServiceGitLab, Label: "Get MR", Description: "Merge request detail.", Category: "MRs", Priority: ToolPriorityEssential},
	{ID: "cb_gitlab_get_mr_diff", Service: domain.MCPServiceGitLab, Label: "MR diff", Description: "Unified diff for an MR.", Category: "MRs", Priority: ToolPriorityEssential},
	{ID: "cb_gitlab_list_mr_changes", Service: domain.MCPServiceGitLab, Label: "MR changes", Description: "Files changed with diff per file.", Category: "MRs", Priority: ToolPriorityCommon},
	{ID: "cb_gitlab_list_mr_notes", Service: domain.MCPServiceGitLab, Label: "MR notes", Description: "Comments / system notes on an MR.", Category: "MRs", Priority: ToolPriorityCommon},
	{ID: "cb_gitlab_list_issues", Service: domain.MCPServiceGitLab, Label: "List issues", Description: "Issues in a project.", Category: "Issues", Priority: ToolPriorityEssential},
	{ID: "cb_gitlab_get_issue", Service: domain.MCPServiceGitLab, Label: "Get issue", Description: "One issue with state and labels.", Category: "Issues", Priority: ToolPriorityCommon},
	{ID: "cb_gitlab_list_issue_notes", Service: domain.MCPServiceGitLab, Label: "Issue notes", Description: "Comments on a GitLab issue.", Category: "Issues", Priority: ToolPriorityCommon},
	{ID: "cb_gitlab_get_file", Service: domain.MCPServiceGitLab, Label: "Read file", Description: "File contents at a ref.", Category: "Repo", Priority: ToolPriorityEssential},
	{ID: "cb_gitlab_list_commits", Service: domain.MCPServiceGitLab, Label: "List commits", Description: "Project commits on a ref.", Category: "Repo", Priority: ToolPriorityCommon},
	{ID: "cb_gitlab_list_branches", Service: domain.MCPServiceGitLab, Label: "List branches", Description: "Project branches.", Category: "Repo", Priority: ToolPriorityCommon},
	{ID: "cb_gitlab_list_pipelines", Service: domain.MCPServiceGitLab, Label: "List pipelines", Description: "CI pipeline runs.", Category: "CI", Priority: ToolPriorityCommon},
	{ID: "cb_gitlab_comment_mr", Service: domain.MCPServiceGitLab, Label: "Comment on MR", Description: "Add a note to an MR. Gated.", Category: "Writes", Priority: ToolPriorityCommon},
	{ID: "cb_gitlab_approve_mr", Service: domain.MCPServiceGitLab, Label: "Approve MR", Description: "Approve a merge request. Gated.", Category: "Writes", Priority: ToolPriorityCommon},
	{ID: "cb_gitlab_create_mr", Service: domain.MCPServiceGitLab, Label: "Open MR", Description: "Create a new merge request. Gated.", Category: "Writes", Priority: ToolPriorityCommon},
	{ID: "cb_gitlab_merge_mr", Service: domain.MCPServiceGitLab, Label: "Merge MR", Description: "Merge a merge request. Destructive — surfaces a modal gate.", Category: "Writes", Priority: ToolPriorityAdvanced},
	{ID: "cb_gitlab_create_issue", Service: domain.MCPServiceGitLab, Label: "Open issue", Description: "Create a new GitLab issue. Gated.", Category: "Writes", Priority: ToolPriorityCommon},
	{ID: "cb_gitlab_update_issue", Service: domain.MCPServiceGitLab, Label: "Edit issue", Description: "Modify title / description / labels / state. Gated.", Category: "Writes", Priority: ToolPriorityAdvanced},
	{ID: "cb_gitlab_close_issue", Service: domain.MCPServiceGitLab, Label: "Close issue", Description: "Close or reopen an issue. Gated.", Category: "Writes", Priority: ToolPriorityAdvanced},

	// SSH tools (cb_ssh_*) are intentionally absent. They're not gated by
	// an MCPService connector — they run against the local SSH registry,
	// not a remote provider — so per-tool toggles don't fit the current
	// model. They always register unless `SSHStore` is nil at Gateway init.

	// ────────────────────────────── Bitwarden
	{ID: "cb_bw_list_folders", Service: domain.MCPServiceBitwarden, Label: "List folders", Description: "Folders inside the unlocked Bitwarden vault.", Category: "Vault", Priority: ToolPriorityCommon},
	{ID: "cb_bw_search_items", Service: domain.MCPServiceBitwarden, Label: "Search items", Description: "Search vault items by name / URL / username.", Category: "Vault", Priority: ToolPriorityEssential},
	{ID: "cb_bw_get_item", Service: domain.MCPServiceBitwarden, Label: "Get item", Description: "Single item by id — surface credentials only on demand.", Category: "Vault", Priority: ToolPriorityCommon},
}

// ToolsForService returns the slice of catalog entries for one service in
// the order they should render — essential first, common, advanced — and
// alphabetised within each priority bucket so successive entries inside
// the same category stay stable across catalog edits.
func ToolsForService(svc domain.MCPService) []ToolMeta {
	var out []ToolMeta
	for _, t := range AllTools {
		if t.Service == svc {
			out = append(out, t)
		}
	}
	// Stable sort: priority ascending, then category, then label.
	for i := 1; i < len(out); i++ {
		for j := i; j > 0; j-- {
			if toolLess(out[j], out[j-1]) {
				out[j], out[j-1] = out[j-1], out[j]
			} else {
				break
			}
		}
	}
	return out
}

func toolLess(a, b ToolMeta) bool {
	if a.Priority != b.Priority {
		return a.Priority < b.Priority
	}
	if a.Category != b.Category {
		return a.Category < b.Category
	}
	return a.Label < b.Label
}

// ToolByID looks up a single tool's metadata. Returns false when the ID
// is not in the catalog — the gateway then treats it as an unknown tool
// (not registered, no toggle UI).
func ToolByID(id string) (ToolMeta, bool) {
	for _, t := range AllTools {
		if t.ID == id {
			return t, true
		}
	}
	return ToolMeta{}, false
}
