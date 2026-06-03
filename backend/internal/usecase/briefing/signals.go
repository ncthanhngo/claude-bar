package briefing

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"sort"
	"time"
)

// Signal is one actionable item in the Workspace feed. Unlike Action (the
// editorial briefing row), a Signal is rule-derived (no Claude in the hot
// path), carries a stable Kind for per-kind drafting/execution, and keeps the
// upstream IDs in Meta so a later approve→execute step can call the matching
// MCP write tool without re-fetching.
type Signal struct {
	ID        string            `json:"id"`
	Kind      string            `json:"kind"`    // mention|dm|email|task_due|meeting_now|meeting_next
	Source    string            `json:"source"`  // slack|gmail|clickup|gcal
	Title     string            `json:"title"`   // primary line
	Context   string            `json:"context"` // secondary line (snippet/status)
	Actor     string            `json:"actor"`   // who: sender / requester / ""
	Timestamp time.Time         `json:"timestamp"`
	Urgency   string            `json:"urgency"`            // urgent|soon|normal
	DeepLink  string            `json:"deepLink,omitempty"` // open-in-app/web url
	Meta      map[string]string `json:"meta,omitempty"`     // IDs for execute layer
}

// WorkspaceFeed is the payload returned by `csw workspace feed --json`.
// Mirrored by widget/.../Backend/WorkspaceDTOs.swift.
type WorkspaceFeed struct {
	SchemaVersion int               `json:"schemaVersion"`
	GeneratedAt   time.Time         `json:"generatedAt"`
	Signals       []Signal          `json:"signals"`
	SourcesHealth map[string]string `json:"sourcesHealth"`
}

// taskDueWindow bounds which ClickUp tasks surface as signals: overdue, or due
// within this window. Tasks far out aren't "today's work" and only add noise.
const taskDueWindow = 48 * time.Hour

// meetingLookahead bounds which upcoming calendar events surface as signals.
const meetingLookahead = 10 * time.Hour

// BuildSignals maps raw MCP data into a sorted Workspace feed. Deterministic:
// the same raw data + now always yields the same signals and order, so the
// widget's "new since last look" diff is stable across polls.
func BuildSignals(raw *RawSourceData, now time.Time) []Signal {
	// Non-nil so the empty feed marshals as `[]`, not `null` — a JSON null
	// breaks the Swift WorkspaceFeedDTO's non-optional [signals] decode.
	out := make([]Signal, 0)

	for _, s := range raw.Slack {
		kind := "mention"
		urgency := "soon"
		if s.IsDM {
			kind = "dm"
			urgency = "urgent"
		}
		out = append(out, Signal{
			ID:        signalID("slack", kind, s.ChannelID+s.TS),
			Kind:      kind,
			Source:    "slack",
			Title:     "Reply " + slackTarget(s),
			Context:   truncate(s.Text, 120),
			Actor:     s.User,
			Timestamp: s.Posted,
			Urgency:   urgency,
			DeepLink:  s.Permalink,
			Meta: map[string]string{
				"channelId": s.ChannelID,
				"ts":        s.TS,
				"threadTs":  s.ThreadTS,
				"user":      s.User,
			},
		})
	}

	for _, e := range raw.Gmail {
		urgency := "normal"
		if e.IsVIP || e.IsStarred {
			urgency = "soon"
		}
		out = append(out, Signal{
			ID:        signalID("gmail", "email", e.ID),
			Kind:      "email",
			Source:    "gmail",
			Title:     "Trả lời " + e.From + ": " + e.Subject,
			Context:   truncate(e.Snippet, 120),
			Actor:     e.From,
			Timestamp: e.ReceivedAt,
			Urgency:   urgency,
			DeepLink:  gmailThreadLink(e.ThreadID),
			Meta: map[string]string{
				"threadId":  e.ThreadID,
				"messageId": e.ID,
				"fromEmail": e.FromEmail,
			},
		})
	}

	for _, t := range raw.ClickUp {
		if t.IsClosed || t.Due.IsZero() {
			continue
		}
		overdue := t.Due.Before(now)
		if !overdue && t.Due.Sub(now) > taskDueWindow {
			continue
		}
		urgency := "soon"
		if overdue || t.Priority == "urgent" {
			urgency = "urgent"
		}
		out = append(out, Signal{
			ID:        signalID("clickup", "task_due", t.ID),
			Kind:      "task_due",
			Source:    "clickup",
			Title:     t.Name,
			Context:   fmt.Sprintf("%s · %s · %s", t.ListName, t.Status, formatTaskDeadline(t.Due, now)),
			Timestamp: t.Due,
			Urgency:   urgency,
			DeepLink:  t.URL,
			Meta: map[string]string{
				"taskId": t.ID,
			},
		})
	}

	for _, c := range raw.GCal {
		if c.Start.IsZero() || c.Status == "cancelled" {
			continue
		}
		ongoing := !c.End.IsZero() && c.Start.Before(now) && c.End.After(now)
		upcoming := c.Start.After(now) && c.Start.Sub(now) <= meetingLookahead
		if !ongoing && !upcoming {
			continue
		}
		kind, urgency := "meeting_next", "normal"
		if ongoing {
			kind, urgency = "meeting_now", "urgent"
		} else if c.Start.Sub(now) <= time.Hour {
			urgency = "soon"
		}
		out = append(out, Signal{
			ID:        signalID("gcal", kind, c.ID),
			Kind:      kind,
			Source:    "gcal",
			Title:     c.Summary,
			Context:   meetingContext(c),
			Timestamp: c.Start,
			Urgency:   urgency,
			Meta: map[string]string{
				"eventId": c.ID,
			},
		})
	}

	sortSignals(out, now)
	return out
}

// sortSignals orders by urgency (urgent→soon→normal), then by the signal's
// natural time: soonest meeting/deadline first for time-based kinds, most
// recent message first for inbox kinds.
func sortSignals(s []Signal, now time.Time) {
	sort.SliceStable(s, func(i, j int) bool {
		ri, rj := urgencyRank(s[i].Urgency), urgencyRank(s[j].Urgency)
		if ri != rj {
			return ri > rj
		}
		return signalSortKey(s[i], now) < signalSortKey(s[j], now)
	})
}

// signalSortKey returns seconds-from-now: future events sort ascending (soonest
// first), past messages sort by smallest age (most recent first) via abs delta.
func signalSortKey(s Signal, now time.Time) float64 {
	d := s.Timestamp.Sub(now).Seconds()
	if d < 0 {
		return -d
	}
	return d
}

func urgencyRank(u string) int {
	switch u {
	case "urgent":
		return 2
	case "soon":
		return 1
	default:
		return 0
	}
}

func meetingContext(c CalItem) string {
	parts := []string{c.Start.Format("15:04")}
	if d := durationLabel(c); d != "" {
		parts[0] += "–" + c.End.Format("15:04")
	}
	if c.Location != "" {
		parts = append(parts, c.Location)
	}
	if c.Attendees > 0 {
		parts = append(parts, fmt.Sprintf("%d người", c.Attendees))
	}
	out := parts[0]
	for _, p := range parts[1:] {
		out += " · " + p
	}
	return out
}

func gmailThreadLink(threadID string) string {
	if threadID == "" {
		return ""
	}
	return "https://mail.google.com/mail/u/0/#all/" + threadID
}

func signalID(source, kind, key string) string {
	h := sha1.New()
	fmt.Fprintf(h, "%s\x00%s\x00%s", source, kind, key)
	return hex.EncodeToString(h.Sum(nil))[:12]
}
