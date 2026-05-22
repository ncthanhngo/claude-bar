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

	"github.com/soi/claude-swap-widget/backend/internal/mcp"
)

const (
	gmailAPIBase   = "https://gmail.googleapis.com/gmail/v1"
	gmailMaxResults = 25
)

// gmailDefaultQuery picks messages worth showing in briefing:
// unread in last 2 days, OR starred / important in last 7 days.
const gmailDefaultQuery = "(is:unread newer_than:2d) OR (is:starred newer_than:7d) OR (is:important newer_than:7d)"

// FetchGmail returns Gmail items via the Google API. Caller passes the
// gateway for OAuth resolution + HTTP reuse.
func FetchGmail(ctx context.Context, g *mcp.Gateway) ([]GmailItem, error) {
	access, err := g.GoogleAccessToken(ctx)
	if err != nil {
		return nil, err
	}
	ids, err := gmailListIDs(ctx, g.HTTPClient(), g.UserAgentString(), access, gmailDefaultQuery, gmailMaxResults)
	if err != nil {
		return nil, err
	}
	items := make([]GmailItem, 0, len(ids))
	for _, id := range ids {
		it, err := gmailGetMeta(ctx, g.HTTPClient(), g.UserAgentString(), access, id)
		if err != nil {
			continue // skip individual failures
		}
		items = append(items, it)
	}
	return items, nil
}

func gmailListIDs(ctx context.Context, hc *http.Client, ua, accessToken, query string, maxResults int) ([]string, error) {
	params := url.Values{}
	params.Set("q", query)
	params.Set("maxResults", strconv.Itoa(maxResults))
	resp, err := googleGet(ctx, hc, ua, accessToken, gmailAPIBase, "/users/me/messages", params)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("gmail list %d: %s", resp.StatusCode, mcp.Redact(strings.TrimSpace(string(body))))
	}
	var out struct {
		Messages []struct {
			ID string `json:"id"`
		} `json:"messages"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("gmail list decode: %w", err)
	}
	ids := make([]string, 0, len(out.Messages))
	for _, m := range out.Messages {
		ids = append(ids, m.ID)
	}
	return ids, nil
}

func gmailGetMeta(ctx context.Context, hc *http.Client, ua, accessToken, id string) (GmailItem, error) {
	params := url.Values{}
	params.Set("format", "metadata")
	params.Add("metadataHeaders", "From")
	params.Add("metadataHeaders", "Subject")
	params.Add("metadataHeaders", "Date")
	resp, err := googleGet(ctx, hc, ua, accessToken, gmailAPIBase, "/users/me/messages/"+url.PathEscape(id), params)
	if err != nil {
		return GmailItem{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		body, _ := io.ReadAll(resp.Body)
		return GmailItem{}, fmt.Errorf("gmail meta %d: %s", resp.StatusCode, mcp.Redact(strings.TrimSpace(string(body))))
	}
	var raw struct {
		ID           string   `json:"id"`
		ThreadID     string   `json:"threadId"`
		Snippet      string   `json:"snippet"`
		LabelIDs     []string `json:"labelIds"`
		InternalDate string   `json:"internalDate"`
		Payload      struct {
			Headers []struct {
				Name  string `json:"name"`
				Value string `json:"value"`
			} `json:"headers"`
		} `json:"payload"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return GmailItem{}, fmt.Errorf("gmail meta decode: %w", err)
	}
	item := GmailItem{
		ID:       raw.ID,
		ThreadID: raw.ThreadID,
		Snippet:  raw.Snippet,
	}
	for _, h := range raw.Payload.Headers {
		switch h.Name {
		case "From":
			item.From, item.FromEmail = parseFromHeader(h.Value)
		case "Subject":
			item.Subject = h.Value
		}
	}
	for _, lid := range raw.LabelIDs {
		switch lid {
		case "UNREAD":
			item.IsUnread = true
		case "STARRED":
			item.IsStarred = true
		}
	}
	if ms, err := strconv.ParseInt(raw.InternalDate, 10, 64); err == nil {
		item.ReceivedAt = time.UnixMilli(ms).UTC()
	}
	return item, nil
}

// parseFromHeader splits "Display Name <email@host>" into ("Display Name", "email@host").
func parseFromHeader(v string) (display, email string) {
	v = strings.TrimSpace(v)
	if i := strings.LastIndex(v, "<"); i != -1 {
		if j := strings.LastIndex(v, ">"); j > i {
			display = strings.TrimSpace(strings.Trim(v[:i], `" `))
			email = strings.TrimSpace(v[i+1 : j])
			if display == "" {
				display = email
			}
			return
		}
	}
	return v, v
}

// googleGet is shared between gmail + gcal fetchers (same auth + bearer).
func googleGet(ctx context.Context, hc *http.Client, ua, accessToken, base, path string, params url.Values) (*http.Response, error) {
	u := base + path
	if len(params) > 0 {
		u += "?" + params.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", ua)
	return hc.Do(req)
}
