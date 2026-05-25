package mcp

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

const (
	gcalAPIBase  = "https://www.googleapis.com/calendar/v3"
	gmailAPIBase = "https://gmail.googleapis.com/gmail/v1"
)

func (g *Gateway) registerGCalTools(srv *server.MCPServer) {
	addTool(srv, "cb_gcal_list_events",
		"List Google Calendar events visible to the active Claude Bar Google token. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("calendar_id", mcpgo.Description("Calendar ID. Default: primary.")),
			mcpgo.WithString("time_min", mcpgo.Description("RFC3339 lower bound. Default: now.")),
			mcpgo.WithString("time_max", mcpgo.Description("RFC3339 upper bound.")),
			mcpgo.WithString("query", mcpgo.Description("Free-text search query.")),
			mcpgo.WithNumber("max_results", mcpgo.Description("Max events (1-50). Default 20.")),
		},
		g.gcalListEvents,
	)

	addTool(srv, "cb_gcal_get_event",
		"Get one Google Calendar event by calendar ID and event ID. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("calendar_id", mcpgo.Description("Calendar ID. Default: primary.")),
			mcpgo.WithString("event_id", mcpgo.Required(), mcpgo.Description("Google Calendar event ID.")),
		},
		g.gcalGetEvent,
	)

	addTool(srv, "cb_gcal_list_calendars",
		"List calendars visible to the active Google token (lets the agent discover calendar IDs before calling list_events). Read-only.",
		nil,
		g.gcalListCalendars,
	)

	addTool(srv, "cb_gcal_get_free_busy",
		"Query free/busy windows for one or more calendars over a time range. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("calendars", mcpgo.Description("Comma-separated calendar IDs. Default: primary.")),
			mcpgo.WithString("time_min", mcpgo.Required(), mcpgo.Description("RFC3339 lower bound.")),
			mcpgo.WithString("time_max", mcpgo.Required(), mcpgo.Description("RFC3339 upper bound.")),
		},
		g.gcalFreeBusy,
	)
}

func (g *Gateway) registerGmailTools(srv *server.MCPServer) {
	addTool(srv, "cb_gmail_search_messages",
		"Search Gmail messages visible to the active Claude Bar Google token. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("query", mcpgo.Description("Gmail search query, e.g. from:alice newer_than:7d.")),
			mcpgo.WithNumber("max_results", mcpgo.Description("Max messages (1-25). Default 10.")),
		},
		g.gmailSearchMessages,
	)

	addTool(srv, "cb_gmail_get_message",
		"Read one Gmail message by ID, returning headers, snippet, and plain text when available. Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("message_id", mcpgo.Required(), mcpgo.Description("Gmail message ID.")),
		},
		g.gmailGetMessage,
	)

	addTool(srv, "cb_gmail_list_labels",
		"List Gmail labels (system + user) so the agent can filter by label ID. Read-only.",
		nil,
		g.gmailListLabels,
	)

	addTool(srv, "cb_gmail_get_thread",
		"Get a full Gmail conversation thread with every message expanded (headers + plain text). Read-only.",
		[]mcpgo.ToolOption{
			mcpgo.WithString("thread_id", mcpgo.Required(), mcpgo.Description("Gmail thread ID (every message in a thread shares it).")),
		},
		g.gmailGetThread,
	)
}

func (g *Gateway) googleAccess(ctx context.Context) (string, error) {
	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceGDrive)
	if err != nil {
		return "", err
	}
	return g.gdriveRefresh(ctx, cc)
}

func (g *Gateway) googleDo(ctx context.Context, accessToken, method, base, path string, params url.Values) (*http.Response, error) {
	u := base + path
	if len(params) > 0 {
		u += "?" + params.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", g.UserAgent)
	return g.HTTP.Do(req)
}

func (g *Gateway) gcalListEvents(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	access, err := g.googleAccess(ctx)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	calendarID := req.GetString("calendar_id", "primary")
	params := url.Values{}
	params.Set("singleEvents", "true")
	params.Set("orderBy", "startTime")
	params.Set("maxResults", strconv.Itoa(clampInt(req.GetInt("max_results", 20), 1, 50)))
	params.Set("timeMin", req.GetString("time_min", time.Now().UTC().Format(time.RFC3339)))
	if timeMax := req.GetString("time_max", ""); timeMax != "" {
		params.Set("timeMax", timeMax)
	}
	if q := req.GetString("query", ""); q != "" {
		params.Set("q", q)
	}
	resp, err := g.googleDo(ctx, access, http.MethodGet, gcalAPIBase, "/calendars/"+url.PathEscape(calendarID)+"/events", params)
	if err != nil {
		return toolErrorf("gcal list events: %v", err), nil
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return toolErrorf("gcal http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body)))), nil
	}
	var out struct {
		Items []map[string]any `json:"items"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return toolErrorf("gcal decode: %v", err), nil
	}
	return jsonResult(out.Items)
}

func (g *Gateway) gcalListCalendars(ctx context.Context, _ mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	access, err := g.googleAccess(ctx)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	resp, err := g.googleDo(ctx, access, http.MethodGet, gcalAPIBase, "/users/me/calendarList", nil)
	if err != nil {
		return toolErrorf("gcal list calendars: %v", err), nil
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return toolErrorf("gcal http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body)))), nil
	}
	var out struct {
		Items []map[string]any `json:"items"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return toolErrorf("gcal decode: %v", err), nil
	}
	return jsonResult(out.Items)
}

func (g *Gateway) gcalFreeBusy(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	access, err := g.googleAccess(ctx)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	timeMin, err := req.RequireString("time_min")
	if err != nil {
		return toolErrorf("time_min is required"), nil
	}
	timeMax, err := req.RequireString("time_max")
	if err != nil {
		return toolErrorf("time_max is required"), nil
	}
	calIDs := []string{"primary"}
	if v := strings.TrimSpace(req.GetString("calendars", "")); v != "" {
		calIDs = nil
		for _, c := range strings.Split(v, ",") {
			if c = strings.TrimSpace(c); c != "" {
				calIDs = append(calIDs, c)
			}
		}
	}
	items := make([]map[string]string, 0, len(calIDs))
	for _, id := range calIDs {
		items = append(items, map[string]string{"id": id})
	}
	payload := map[string]any{"timeMin": timeMin, "timeMax": timeMax, "items": items}

	buf, _ := json.Marshal(payload)
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, gcalAPIBase+"/freeBusy", strings.NewReader(string(buf)))
	if err != nil {
		return toolErrorf("gcal freebusy: %v", err), nil
	}
	httpReq.Header.Set("Authorization", "Bearer "+access)
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json")
	httpReq.Header.Set("User-Agent", g.UserAgent)
	resp, err := g.HTTP.Do(httpReq)
	if err != nil {
		return toolErrorf("gcal freebusy: %v", err), nil
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return toolErrorf("gcal http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body)))), nil
	}
	return mcpgo.NewToolResultText(string(body)), nil
}

func (g *Gateway) gcalGetEvent(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	access, err := g.googleAccess(ctx)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	eventID, err := req.RequireString("event_id")
	if err != nil {
		return toolErrorf("event_id is required"), nil
	}
	calendarID := req.GetString("calendar_id", "primary")
	resp, err := g.googleDo(ctx, access, http.MethodGet, gcalAPIBase, "/calendars/"+url.PathEscape(calendarID)+"/events/"+url.PathEscape(eventID), nil)
	if err != nil {
		return toolErrorf("gcal get event: %v", err), nil
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return toolErrorf("gcal http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body)))), nil
	}
	return mcpgo.NewToolResultText(string(body)), nil
}

func (g *Gateway) gmailSearchMessages(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	access, err := g.googleAccess(ctx)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	params := url.Values{}
	params.Set("maxResults", strconv.Itoa(clampInt(req.GetInt("max_results", 10), 1, 25)))
	if q := req.GetString("query", ""); q != "" {
		params.Set("q", q)
	}
	resp, err := g.googleDo(ctx, access, http.MethodGet, gmailAPIBase, "/users/me/messages", params)
	if err != nil {
		return toolErrorf("gmail search: %v", err), nil
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return toolErrorf("gmail http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body)))), nil
	}
	return mcpgo.NewToolResultText(string(body)), nil
}

func (g *Gateway) gmailListLabels(ctx context.Context, _ mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	access, err := g.googleAccess(ctx)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	resp, err := g.googleDo(ctx, access, http.MethodGet, gmailAPIBase, "/users/me/labels", nil)
	if err != nil {
		return toolErrorf("gmail list labels: %v", err), nil
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return toolErrorf("gmail http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body)))), nil
	}
	var out struct {
		Labels []map[string]any `json:"labels"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return toolErrorf("gmail decode: %v", err), nil
	}
	return jsonResult(out.Labels)
}

func (g *Gateway) gmailGetThread(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	access, err := g.googleAccess(ctx)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	threadID, err := req.RequireString("thread_id")
	if err != nil {
		return toolErrorf("thread_id is required"), nil
	}
	params := url.Values{}
	params.Set("format", "full")
	resp, err := g.googleDo(ctx, access, http.MethodGet, gmailAPIBase, "/users/me/threads/"+url.PathEscape(threadID), params)
	if err != nil {
		return toolErrorf("gmail get thread: %v", err), nil
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return toolErrorf("gmail http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body)))), nil
	}
	var thread struct {
		ID       string         `json:"id"`
		Messages []gmailMessage `json:"messages"`
	}
	if err := json.Unmarshal(body, &thread); err != nil {
		return toolErrorf("gmail decode: %v", err), nil
	}
	out := make([]map[string]any, 0, len(thread.Messages))
	for _, m := range thread.Messages {
		out = append(out, map[string]any{
			"id":       m.ID,
			"threadId": m.ThreadID,
			"snippet":  m.Snippet,
			"headers":  m.headerMap(),
			"text":     strings.TrimSpace(extractGmailPlainText(m.Payload)),
		})
	}
	return jsonResult(map[string]any{"id": thread.ID, "messages": out})
}

func (g *Gateway) gmailGetMessage(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	access, err := g.googleAccess(ctx)
	if err != nil {
		return toolErrorForResolve(err), nil
	}
	messageID, err := req.RequireString("message_id")
	if err != nil {
		return toolErrorf("message_id is required"), nil
	}
	params := url.Values{}
	params.Set("format", "full")
	resp, err := g.googleDo(ctx, access, http.MethodGet, gmailAPIBase, "/users/me/messages/"+url.PathEscape(messageID), params)
	if err != nil {
		return toolErrorf("gmail get message: %v", err), nil
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return toolErrorf("gmail http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body)))), nil
	}
	var msg gmailMessage
	if err := json.Unmarshal(body, &msg); err != nil {
		return toolErrorf("gmail decode: %v", err), nil
	}
	return jsonResult(map[string]any{
		"id":       msg.ID,
		"threadId": msg.ThreadID,
		"snippet":  msg.Snippet,
		"headers":  msg.headerMap(),
		"text":     strings.TrimSpace(extractGmailPlainText(msg.Payload)),
	})
}

type gmailMessage struct {
	ID       string       `json:"id"`
	ThreadID string       `json:"threadId"`
	Snippet  string       `json:"snippet"`
	Payload  gmailPayload `json:"payload"`
}

type gmailPayload struct {
	MimeType string        `json:"mimeType"`
	Headers  []gmailHeader `json:"headers"`
	Body     struct {
		Data string `json:"data"`
	} `json:"body"`
	Parts []gmailPayload `json:"parts"`
}

type gmailHeader struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

func (m gmailMessage) headerMap() map[string]string {
	keep := map[string]bool{"From": true, "To": true, "Cc": true, "Date": true, "Subject": true}
	out := map[string]string{}
	for _, h := range m.Payload.Headers {
		if keep[h.Name] {
			out[h.Name] = h.Value
		}
	}
	return out
}

func extractGmailPlainText(p gmailPayload) string {
	var chunks []string
	var walk func(gmailPayload)
	walk = func(part gmailPayload) {
		if strings.HasPrefix(part.MimeType, "text/plain") && part.Body.Data != "" {
			if b, err := base64.RawURLEncoding.DecodeString(part.Body.Data); err == nil {
				chunks = append(chunks, string(b))
			}
		}
		for _, child := range part.Parts {
			walk(child)
		}
	}
	walk(p)
	return strings.Join(chunks, "\n\n")
}
