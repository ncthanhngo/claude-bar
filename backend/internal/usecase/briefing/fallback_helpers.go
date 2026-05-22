package briefing

import (
	"fmt"
	"strings"
	"time"
)

// Helper functions used by FallbackRank. Kept in a separate file so the
// ranker stays focused on weighting + classification logic.

func emailMeta(e GmailItem) string {
	if e.IsVIP {
		return "email · VIP"
	}
	if e.IsStarred {
		return "email · starred"
	}
	return "email"
}

func slackTarget(s SlackItem) string {
	if s.IsDM {
		return "DM " + s.User
	}
	return "@" + s.User
}

func slackChannelLabel(s SlackItem) string {
	if s.IsDM {
		return "DM"
	}
	if s.Channel != "" {
		return "#" + s.Channel
	}
	return "channel"
}

func formatTaskDeadline(due, today time.Time) string {
	if due.IsZero() {
		return "trong tuần"
	}
	if due.Before(today) {
		return "quá hạn"
	}
	if due.Sub(today) <= 24*time.Hour {
		return "due hôm nay"
	}
	return due.Format("02/01")
}

func durationLabel(c CalItem) string {
	if c.End.IsZero() || c.Start.IsZero() {
		return ""
	}
	mins := int(c.End.Sub(c.Start).Minutes())
	return fmt.Sprintf("%dp", mins)
}

func calendarPayload(events []CalItem, today time.Time) []PayloadCal {
	out := make([]PayloadCal, 0, len(events))
	for _, e := range events {
		if e.Start.IsZero() {
			continue
		}
		state := "next"
		switch {
		case e.End.Before(today):
			state = "done"
		case !e.End.IsZero() && e.Start.Before(today) && e.End.After(today):
			state = "now"
		}
		out = append(out, PayloadCal{
			Time:     e.Start.Format("15:04"),
			EndTime:  e.End.Format("15:04"),
			State:    state,
			Title:    e.Summary,
			Subtitle: e.Location,
		})
		if len(out) >= 5 {
			break
		}
	}
	return out
}

func focusBody(actions []PayloadAction) string {
	if len(actions) == 0 {
		return "Không có việc nổi bật — tận hưởng buổi sáng nhẹ nhàng."
	}
	a := actions[0]
	return fmt.Sprintf("Bắt đầu với **%s** — %s.", a.Title, a.Deadline)
}

func vnSpellNumber(n int) string {
	words := []string{"Không", "Một", "Hai", "Ba", "Bốn", "Năm", "Sáu", "Bảy", "Tám", "Chín", "Mười"}
	if n >= 0 && n <= 10 {
		return words[n]
	}
	return fmt.Sprintf("%d", n)
}

func truncate(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
