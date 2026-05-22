package briefing

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/mcp"
)

const clickupAPIBase = "https://api.clickup.com/api/v2"

// FetchClickUp returns open tasks assigned to the authenticated user with due
// date in the next 7 days. Strategy:
//  1. GET /user → resolve user_id
//  2. GET /team → first team
//  3. GET /team/{id}/task?assignees[]=user_id&include_closed=false&due_date_lt=+7d
func FetchClickUp(ctx context.Context, g *mcp.Gateway) ([]TaskItem, error) {
	token, err := g.ServiceToken(ctx, domain.MCPServiceClickUp)
	if err != nil {
		return nil, err
	}
	hc := g.HTTPClient()
	ua := g.UserAgentString()

	userID, err := clickupUserID(ctx, hc, ua, token)
	if err != nil {
		return nil, fmt.Errorf("clickup user: %w", err)
	}
	teamID, err := clickupFirstTeam(ctx, hc, ua, token)
	if err != nil {
		return nil, fmt.Errorf("clickup team: %w", err)
	}
	return clickupListTasks(ctx, hc, ua, token, teamID, userID)
}

func clickupUserID(ctx context.Context, hc *http.Client, ua, token string) (string, error) {
	resp, err := clickupGet(ctx, hc, ua, token, "/user", nil)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return "", fmt.Errorf("http %d: %s", resp.StatusCode, mcp.Redact(strings.TrimSpace(string(body))))
	}
	var out struct {
		User struct {
			ID int64 `json:"id"`
		} `json:"user"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return "", err
	}
	return strconv.FormatInt(out.User.ID, 10), nil
}

func clickupFirstTeam(ctx context.Context, hc *http.Client, ua, token string) (string, error) {
	resp, err := clickupGet(ctx, hc, ua, token, "/team", nil)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return "", fmt.Errorf("http %d: %s", resp.StatusCode, mcp.Redact(strings.TrimSpace(string(body))))
	}
	var out struct {
		Teams []struct {
			ID string `json:"id"`
		} `json:"teams"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return "", err
	}
	if len(out.Teams) == 0 {
		return "", fmt.Errorf("no clickup teams accessible")
	}
	return out.Teams[0].ID, nil
}

func clickupListTasks(ctx context.Context, hc *http.Client, ua, token, teamID, userID string) ([]TaskItem, error) {
	dueLT := time.Now().Add(7 * 24 * time.Hour).UnixMilli()
	params := url.Values{}
	params.Add("assignees[]", userID)
	params.Set("include_closed", "false")
	params.Set("subtasks", "false")
	params.Set("due_date_lt", strconv.FormatInt(dueLT, 10))
	params.Set("order_by", "due_date")
	params.Set("page", "0")

	resp, err := clickupGet(ctx, hc, ua, token, "/team/"+teamID+"/task", params)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("http %d: %s", resp.StatusCode, mcp.Redact(strings.TrimSpace(string(body))))
	}
	var raw struct {
		Tasks []struct {
			ID     string `json:"id"`
			Name   string `json:"name"`
			Status struct {
				Status string `json:"status"`
				Type   string `json:"type"`
			} `json:"status"`
			Priority struct {
				Priority string `json:"priority"`
			} `json:"priority"`
			List struct {
				Name string `json:"name"`
			} `json:"list"`
			DueDate string `json:"due_date"`
			URL     string `json:"url"`
		} `json:"tasks"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, err
	}
	out := make([]TaskItem, 0, len(raw.Tasks))
	for _, t := range raw.Tasks {
		item := TaskItem{
			ID:         t.ID,
			Name:       t.Name,
			ListName:   t.List.Name,
			Status:     t.Status.Status,
			Priority:   t.Priority.Priority,
			URL:        t.URL,
			IsClosed:   t.Status.Type == "closed",
			AssignedMe: true,
		}
		if t.DueDate != "" {
			if ms, err := strconv.ParseInt(t.DueDate, 10, 64); err == nil {
				item.Due = time.UnixMilli(ms).UTC()
			}
		}
		out = append(out, item)
	}
	return out, nil
}

func clickupGet(ctx context.Context, hc *http.Client, ua, token, path string, params url.Values) (*http.Response, error) {
	u := clickupAPIBase + path
	if len(params) > 0 {
		u += "?" + params.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", token)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", ua)
	return hc.Do(req)
}
