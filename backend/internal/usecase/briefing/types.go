// Package briefing defines DTO types and storage paths for the Daily Briefing feature.
//
// Schema mirrored exactly by widget/Sources/ClaudeSwapWidget/Backend/BriefingDTOs.swift.
// Mockup section reference: daily-briefing-preview.html.
package briefing

import "time"

// SchemaVersion bumps when DTO shape changes incompatibly.
const SchemaVersion = 1

// Briefing is the full daily report rendered by the widget.
type Briefing struct {
	SchemaVersion int               `json:"schemaVersion"`
	Date          string            `json:"date"` // "2026-05-21"
	GeneratedAt   time.Time         `json:"generatedAt"`
	NextRunAt     time.Time         `json:"nextRunAt"`
	Hero          Hero              `json:"hero"`
	Actions       []Action          `json:"actions"`
	Calendar      []CalEvent        `json:"calendar"`
	Stats         BriefingStats     `json:"stats"`
	SourcesHealth map[string]string `json:"sourcesHealth"` // "gmail":"ok"|"expired"|"down"
}

// Hero drives the serif headline + focus banner above the action list.
type Hero struct {
	Eyebrow     string `json:"eyebrow"`     // "Hôm nay bạn cần làm"
	Title       string `json:"title"`       // "Bảy việc đang chờ — một cảnh báo cần xử trí."
	FocusBadge  string `json:"focusBadge"`  // "trước tiên"
	FocusBody   string `json:"focusBody"`   // sentence linking the #1 priority item
	CountNumber int    `json:"countNumber"` // 7
	CountLabel  string `json:"countLabel"`  // "việc · 3 urgent · 2 soon"
}

// Action is one row in the daily todo list.
type Action struct {
	ID           string `json:"id"`
	Index        int    `json:"index"`        // 1..N (display order)
	Priority     string `json:"priority"`     // "urgent" | "important" | "normal"
	Title        string `json:"title"`
	Source       string `json:"source"`       // "email" | "task" | "slack" | "meet"
	SourceMeta   string `json:"sourceMeta"`   // "email · VIP" | "task · ClickUp"
	Context      string `json:"context"`      // italic context line under title
	Deadline     string `json:"deadline"`     // "trước 17:00" | "due hôm nay"
	DeadlineHint string `json:"deadlineHint"` // sub-line under deadline
	DeadlineTone string `json:"deadlineTone"` // "urgent" | "soon" | "normal" | "done"
	Done         bool   `json:"done"`
	DeepLink     string `json:"deepLink,omitempty"` // optional gmail/clickup/slack url
}

// CalEvent is one row on the right-side timeline.
type CalEvent struct {
	Time     string `json:"time"`     // "10:30"
	EndTime  string `json:"endTime"`  // "11:15"
	State    string `json:"state"`    // "done" | "now" | "next"
	Title    string `json:"title"`
	Subtitle string `json:"subtitle"`
	Flag     string `json:"flag,omitempty"` // "cần chuẩn bị demo"
}

// BriefingStats are the small counters next to the hero.
type BriefingStats struct {
	Total     int `json:"total"`
	Urgent    int `json:"urgent"`
	Important int `json:"important"`
	Done      int `json:"done"`
}

// ScheduleMode picks between cron mode (legacy daily briefing) and interval
// mode (Phase 6: live push every N minutes).
type ScheduleMode string

const (
	ScheduleModeCron     ScheduleMode = "cron"
	ScheduleModeInterval ScheduleMode = "interval"
)

// Schedule controls when the scheduler fires.
type Schedule struct {
	SchemaVersion int          `json:"schemaVersion"`
	Mode          ScheduleMode `json:"mode,omitempty"` // "cron" (default) | "interval"
	CronExpr      string       `json:"cronExpr"`       // "33 8 * * 1-5" (cron mode)
	IntervalMinutes int        `json:"intervalMinutes,omitempty"` // 5/15/30/60 (interval mode)
	Enabled       bool         `json:"enabled"`
	Timezone      string       `json:"timezone"` // "Asia/Saigon"
	LastRunAt     string       `json:"lastRunAt"`
	LastRunStatus string       `json:"lastRunStatus"`

	// QuietHoursStart/End is a daily window during which notifications are
	// muted (HH:MM, 24h). Empty values disable quiet hours. Pull continues
	// inside the window — only the macOS notification is suppressed.
	QuietHoursStart string `json:"quietHoursStart,omitempty"`
	QuietHoursEnd   string `json:"quietHoursEnd,omitempty"`
}

// DefaultSchedule returns the seed config (08:33 Mon-Fri Asia/Saigon).
func DefaultSchedule() Schedule {
	return Schedule{
		SchemaVersion: SchemaVersion,
		CronExpr:      "33 8 * * 1-5",
		Enabled:       true,
		Timezone:      "Asia/Saigon",
	}
}
