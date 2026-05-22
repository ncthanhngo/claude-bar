package briefing

import (
	"fmt"
	"sort"
	"time"
)

// FallbackRank produces a BriefingPayload from raw data using deterministic
// weights only. Used when Claude is unreachable / returns garbage.
//
// Weight: overdue(+100) + due_within_24h(+50) + VIP(+30) + mention(+20) + unread(+5)
// Top 7 by weight. Top 3 -> urgent, next 2 -> important, rest -> normal.
func FallbackRank(raw *RawSourceData, today time.Time) *BriefingPayload {
	type weighted struct {
		w      int
		action PayloadAction
	}
	var pool []weighted

	for _, t := range raw.ClickUp {
		w := 0
		if !t.Due.IsZero() {
			if t.Due.Before(today) {
				w += 100
			} else if t.Due.Sub(today) <= 24*time.Hour {
				w += 50
			}
		}
		if t.Priority == "urgent" {
			w += 30
		} else if t.Priority == "high" {
			w += 15
		}
		pool = append(pool, weighted{w, PayloadAction{
			Title:      t.Name,
			Source:     "task",
			SourceMeta: "task · ClickUp",
			Context:    fmt.Sprintf("list %s · %s", t.ListName, t.Status),
			Deadline:   formatTaskDeadline(t.Due, today),
			DeepLink:   t.URL,
		}})
	}

	for _, e := range raw.Gmail {
		w := 5
		if e.IsStarred {
			w += 20
		}
		if e.IsVIP {
			w += 30
		}
		pool = append(pool, weighted{w, PayloadAction{
			Title:      "Trả lời " + e.From + ": " + e.Subject,
			Source:     "email",
			SourceMeta: emailMeta(e),
			Context:    truncate(e.Snippet, 90),
			Deadline:   "hôm nay",
		}})
	}

	for _, s := range raw.Slack {
		w := 5
		if s.IsMention {
			w += 20
		}
		if s.IsDM {
			w += 25
		}
		pool = append(pool, weighted{w, PayloadAction{
			Title:      "Reply " + slackTarget(s),
			Source:     "slack",
			SourceMeta: "slack · " + slackChannelLabel(s),
			Context:    truncate(s.Text, 90),
			Deadline:   s.Posted.Format("15:04"),
			DeepLink:   s.Permalink,
		}})
	}

	for _, c := range raw.GCal {
		if c.Start.IsZero() {
			continue
		}
		w := 10
		if c.Start.Sub(today) <= 2*time.Hour && c.Start.After(today) {
			w += 25
		}
		pool = append(pool, weighted{w, PayloadAction{
			Title:      "Chuẩn bị cho " + c.Summary,
			Source:     "meet",
			SourceMeta: fmt.Sprintf("lịch · %s", durationLabel(c)),
			Context:    c.Location,
			Deadline:   c.Start.Format("15:04"),
		}})
	}

	sort.Slice(pool, func(i, j int) bool { return pool[i].w > pool[j].w })
	if len(pool) > 7 {
		pool = pool[:7]
	}

	actions := make([]PayloadAction, len(pool))
	urgentN, importantN := 0, 0
	for i, p := range pool {
		a := p.action
		switch {
		case i < 3:
			a.Priority = "urgent"
			a.DeadlineTone = "urgent"
			urgentN++
		case i < 5:
			a.Priority = "important"
			a.DeadlineTone = "soon"
			importantN++
		default:
			a.Priority = "normal"
			a.DeadlineTone = "normal"
		}
		actions[i] = a
	}

	hero := PayloadHero{
		Eyebrow:     "Hôm nay bạn cần làm",
		Title:       fmt.Sprintf("%s *việc* đang chờ — sẵn sàng cho ngày mới.", vnSpellNumber(len(actions))),
		FocusBadge:  "trước tiên",
		FocusBody:   focusBody(actions),
		CountNumber: len(actions),
		CountLabel:  fmt.Sprintf("việc · %d urgent · %d soon", urgentN, importantN),
	}
	return &BriefingPayload{
		Hero:    hero,
		Actions: actions,
		Calendar: calendarPayload(raw.GCal, today),
	}
}

