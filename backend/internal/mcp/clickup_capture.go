package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// CaptureParsed is the structured form the Command Center capture box yields
// from a freeform input line like:
//
//	fix login bug !high @vy due fri #Inbox
//
// Tokens are stripped from `Text` and surfaced as separate fields. Unknown
// tokens stay in the resulting task title.
type CaptureParsed struct {
	Text       string   `json:"text"`
	ListHint   string   `json:"listHint,omitempty"`
	Priority   string   `json:"priority,omitempty"` // urgent | high | normal | low
	Assignees  []string `json:"assignees,omitempty"`
	DueHint    string   `json:"dueHint,omitempty"`  // user-typed token (today, fri, etc.)
}

// ParseCapture tokenises a capture-box input. Pure function — no I/O — so
// it's trivial to unit test against fixtures.
func ParseCapture(input string) CaptureParsed {
	out := CaptureParsed{}
	tokens := strings.Fields(strings.TrimSpace(input))
	keep := make([]string, 0, len(tokens))
	priorityWord := map[string]string{
		"!urgent": "urgent",
		"!high":   "high",
		"!normal": "normal",
		"!low":    "low",
	}
	dueRe := regexp.MustCompile(`^due$`)
	pendingDue := false

	for _, t := range tokens {
		switch {
		case pendingDue:
			out.DueHint = strings.ToLower(strings.TrimPrefix(t, "@"))
			pendingDue = false
			continue
		case strings.HasPrefix(t, "#") && len(t) > 1:
			if out.ListHint == "" {
				out.ListHint = strings.TrimPrefix(t, "#")
				continue
			}
		case strings.HasPrefix(t, "@") && len(t) > 1:
			out.Assignees = append(out.Assignees, strings.TrimPrefix(t, "@"))
			continue
		case priorityWord[strings.ToLower(t)] != "":
			out.Priority = priorityWord[strings.ToLower(t)]
			continue
		case dueRe.MatchString(strings.ToLower(t)):
			pendingDue = true
			continue
		}
		keep = append(keep, t)
	}
	out.Text = strings.TrimSpace(strings.Join(keep, " "))
	return out
}

// registerClickUpCaptureTool registers `cb_clickup_capture` — the single
// entrypoint for the Command Center capture box. The widget tags this call
// with Origin=OriginCapture; the gate may auto-confirm when the user has
// trust-capture enabled (enforced server-side per Red-Team Finding 13).
func (g *Gateway) registerClickUpCaptureTool(srv *server.MCPServer) {
	addTool(srv, "cb_clickup_capture",
		"Create a ClickUp task from a capture-box input (tokens: #list, @assignee, !priority, due <word>). Gated.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("input", mcpgo.Required(), mcpgo.Description("Raw capture-box text.")),
			mcpgo.WithString("default_list_id", mcpgo.Description("Fallback ClickUp list id when no #list token.")),
			mcpgo.WithString("origin", mcpgo.Description("Origin tag: 'capture' (default) or 'llm'.")),
		},
		g.clickupCapture,
	)
}

func (g *Gateway) clickupCapture(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceClickUp)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	input, err := req.RequireString("input")
	if err != nil || strings.TrimSpace(input) == "" {
		return toolErrorf("input is required"), nil
	}
	defaultList := strings.TrimSpace(req.GetString("default_list_id", ""))
	originStr := strings.ToLower(strings.TrimSpace(req.GetString("origin", "capture")))

	parsed := ParseCapture(input)
	if parsed.Text == "" {
		return toolErrorf("capture input has no task title after token parsing"), nil
	}

	listID := defaultList
	if parsed.ListHint != "" {
		// Capture box ListHint is the human label. The widget is expected to
		// have resolved it to a list_id and pass it via default_list_id. For
		// safety, if no default is provided, fail rather than guess.
		if defaultList == "" {
			return toolErrorf("capture #%s requires the widget to pass default_list_id (cannot resolve list by name from backend)", parsed.ListHint), nil
		}
	}
	if listID == "" {
		return toolErrorf("no list id available — pass default_list_id or include #list token"), nil
	}

	origin := OriginCapture
	if originStr == "llm" {
		origin = OriginLLM
	}

	args := map[string]any{
		"text":      parsed.Text,
		"list_id":   listID,
		"priority":  parsed.Priority,
		"assignees": parsed.Assignees,
		"due":       parsed.DueHint,
		"origin":    originStr,
	}
	summary := fmt.Sprintf("ClickUp capture: %q in list %s", parsed.Text, listID)

	return g.runThroughGate(ctx, writeGateRequest{
		Tool:    "cb_clickup_capture",
		Risk:    RiskLow,
		Origin:  origin,
		Summary: summary,
		Args:    args,
		Account: strconv.Itoa(cc.AccountNumber),
		Execute: func(ctx context.Context) (*mcpgo.CallToolResult, error) {
			payload := map[string]any{"name": parsed.Text}
			if code, ok := priorityCodes[parsed.Priority]; ok {
				payload["priority"] = code
			}
			if parsed.DueHint != "" {
				payload["due_date_string"] = parsed.DueHint
			}
			body, _, err := g.clickupBodyJSON(ctx, http.MethodPost, cc.Payload, "/list/"+listID+"/task", payload)
			if err != nil {
				return toolErrorf("clickup capture create: %v", err), nil
			}
			var out map[string]any
			_ = json.Unmarshal(body, &out)
			return jsonResult(out)
		},
	})
}
