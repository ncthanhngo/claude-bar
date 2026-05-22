package briefing

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"strings"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/mcp"
)

const gcalAPIBase = "https://www.googleapis.com/calendar/v3"

// FetchGCal returns events on the primary calendar between now-1h and +36h
// (covers remaining slots today + tomorrow morning meetings).
func FetchGCal(ctx context.Context, g *mcp.Gateway) ([]CalItem, error) {
	access, err := g.GoogleAccessToken(ctx)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	timeMin := now.Add(-1 * time.Hour).UTC().Format(time.RFC3339)
	timeMax := now.Add(36 * time.Hour).UTC().Format(time.RFC3339)
	params := url.Values{}
	params.Set("singleEvents", "true")
	params.Set("orderBy", "startTime")
	params.Set("maxResults", "50")
	params.Set("timeMin", timeMin)
	params.Set("timeMax", timeMax)
	resp, err := googleGet(ctx, g.HTTPClient(), g.UserAgentString(), access, gcalAPIBase, "/calendars/primary/events", params)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("gcal list %d: %s", resp.StatusCode, mcp.Redact(strings.TrimSpace(string(body))))
	}
	var raw struct {
		Items []struct {
			ID         string `json:"id"`
			Summary    string `json:"summary"`
			Location   string `json:"location"`
			Status     string `json:"status"`
			Recurring  string `json:"recurringEventId"`
			Start      gcalTime `json:"start"`
			End        gcalTime `json:"end"`
			Attendees  []struct {
				Email string `json:"email"`
			} `json:"attendees"`
		} `json:"items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return nil, fmt.Errorf("gcal decode: %w", err)
	}
	items := make([]CalItem, 0, len(raw.Items))
	for _, ev := range raw.Items {
		start, allDay := parseGCalTime(ev.Start)
		end, _ := parseGCalTime(ev.End)
		items = append(items, CalItem{
			ID:          ev.ID,
			Summary:     strings.TrimSpace(ev.Summary),
			Start:       start,
			End:         end,
			IsAllDay:    allDay,
			Location:    ev.Location,
			Attendees:   len(ev.Attendees),
			IsRecurring: ev.Recurring != "",
			Status:      ev.Status,
		})
	}
	return items, nil
}

type gcalTime struct {
	DateTime string `json:"dateTime"`
	Date     string `json:"date"`
	TimeZone string `json:"timeZone"`
}

func parseGCalTime(t gcalTime) (time.Time, bool) {
	if t.Date != "" {
		if v, err := time.Parse("2006-01-02", t.Date); err == nil {
			return v, true
		}
	}
	if t.DateTime != "" {
		if v, err := time.Parse(time.RFC3339, t.DateTime); err == nil {
			return v, false
		}
	}
	return time.Time{}, false
}
