package mcp

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

const slackAPIBase = "https://slack.com/api"

// slackResponse is the common Slack API envelope.
type slackResponse struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

// slackCall does GET ${slackAPIBase}/${method} with the user token in
// Authorization. Params are url-encoded as the query string per Slack docs.
func (g *Gateway) slackCall(ctx context.Context, token, method string, params url.Values, out any) error {
	u := slackAPIBase + "/" + method
	if len(params) > 0 {
		u += "?" + params.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", g.UserAgent)

	resp, err := g.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("slack http: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("slack read: %w", err)
	}
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("slack http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body))))
	}
	var envelope slackResponse
	if err := json.Unmarshal(body, &envelope); err != nil {
		return fmt.Errorf("slack decode: %w", err)
	}
	if !envelope.OK {
		return fmt.Errorf("slack: %s", envelope.Error)
	}
	if out != nil {
		if err := json.Unmarshal(body, out); err != nil {
			return fmt.Errorf("slack decode payload: %w", err)
		}
	}
	return nil
}

// slackPostJSON sends a JSON-body POST to a Slack Web API method. Slack
// accepts JSON bodies on write endpoints (chat.postMessage etc.) and
// returns the same `{ok, error}` envelope as GET.
func (g *Gateway) slackPostJSON(ctx context.Context, token, method string, payload any, out any) error {
	buf, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("encode body: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, slackAPIBase+"/"+method, bytes.NewReader(buf))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", g.UserAgent)

	resp, err := g.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("slack http: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("slack read: %w", err)
	}
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("slack http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body))))
	}
	var envelope slackResponse
	if err := json.Unmarshal(body, &envelope); err != nil {
		return fmt.Errorf("slack decode: %w", err)
	}
	if !envelope.OK {
		return fmt.Errorf("slack: %s", envelope.Error)
	}
	if out != nil {
		if err := json.Unmarshal(body, out); err != nil {
			return fmt.Errorf("slack decode payload: %w", err)
		}
	}
	return nil
}
