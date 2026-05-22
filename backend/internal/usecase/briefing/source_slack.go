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

const (
	slackAPIBase   = "https://slack.com/api"
	slackMaxResult = 25
)

// FetchSlack returns recent @me mentions and direct messages (last 24h).
// Strategy: search.messages with query `(@me OR is:dm) newer_than:1d`.
// Falls back to mentions-only if DMs aren't searchable on the token.
func FetchSlack(ctx context.Context, g *mcp.Gateway) ([]SlackItem, error) {
	token, err := g.ServiceToken(ctx, domain.MCPServiceSlack)
	if err != nil {
		return nil, err
	}
	hc := g.HTTPClient()
	ua := g.UserAgentString()

	uid, err := slackSelfID(ctx, hc, ua, token)
	if err != nil {
		return nil, fmt.Errorf("slack auth.test: %w", err)
	}

	query := fmt.Sprintf("(<@%s> OR is:dm) newer_than:1d", uid)
	items, err := slackSearch(ctx, hc, ua, token, query, slackMaxResult, uid)
	if err != nil {
		return nil, err
	}
	return items, nil
}

func slackSelfID(ctx context.Context, hc *http.Client, ua, token string) (string, error) {
	resp, err := slackGet(ctx, hc, ua, token, "auth.test", nil)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return "", fmt.Errorf("http %d: %s", resp.StatusCode, mcp.Redact(strings.TrimSpace(string(body))))
	}
	var out struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
		UserID string `json:"user_id"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return "", err
	}
	if !out.OK {
		return "", fmt.Errorf("slack: %s", out.Error)
	}
	return out.UserID, nil
}

func slackSearch(ctx context.Context, hc *http.Client, ua, token, query string, count int, selfID string) ([]SlackItem, error) {
	params := url.Values{}
	params.Set("query", query)
	params.Set("count", strconv.Itoa(count))
	params.Set("sort", "timestamp")
	params.Set("sort_dir", "desc")
	resp, err := slackGet(ctx, hc, ua, token, "search.messages", params)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("http %d: %s", resp.StatusCode, mcp.Redact(strings.TrimSpace(string(body))))
	}
	var raw struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
		Messages struct {
			Matches []struct {
				Channel struct {
					ID   string `json:"id"`
					Name string `json:"name"`
					IsIm bool   `json:"is_im"`
				} `json:"channel"`
				Username  string `json:"username"`
				User      string `json:"user"`
				Text      string `json:"text"`
				TS        string `json:"ts"`
				ThreadTS  string `json:"thread_ts"`
				Permalink string `json:"permalink"`
			} `json:"matches"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, err
	}
	if !raw.OK {
		return nil, fmt.Errorf("slack: %s", raw.Error)
	}
	items := make([]SlackItem, 0, len(raw.Messages.Matches))
	for _, m := range raw.Messages.Matches {
		posted := time.Time{}
		if i := strings.Index(m.TS, "."); i > 0 {
			if s, err := strconv.ParseInt(m.TS[:i], 10, 64); err == nil {
				posted = time.Unix(s, 0).UTC()
			}
		}
		items = append(items, SlackItem{
			Channel:   m.Channel.Name,
			ChannelID: m.Channel.ID,
			User:      firstNonEmpty(m.Username, m.User),
			Text:      m.Text,
			TS:        m.TS,
			ThreadTS:  m.ThreadTS,
			Posted:    posted,
			IsMention: strings.Contains(m.Text, "<@"+selfID+">"),
			IsDM:      m.Channel.IsIm,
			Permalink: m.Permalink,
		})
	}
	return items, nil
}

func slackGet(ctx context.Context, hc *http.Client, ua, token, method string, params url.Values) (*http.Response, error) {
	u := slackAPIBase + "/" + method
	if len(params) > 0 {
		u += "?" + params.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", ua)
	return hc.Do(req)
}

func firstNonEmpty(s ...string) string {
	for _, v := range s {
		if v != "" {
			return v
		}
	}
	return ""
}
