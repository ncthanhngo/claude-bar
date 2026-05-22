package briefing

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
)

// ConnectorPrompts mirrors the widget's MCPConnectorPrompts JSON shape.
// All fields are optional; an empty string means "no user override for
// this connector". JSON keys match the Tag.rawValue on the Swift side.
type ConnectorPrompts struct {
	Slack   string `json:"slack,omitempty"`
	Clickup string `json:"clickup,omitempty"`
	GDrive  string `json:"gdrive,omitempty"`
	Gmail   string `json:"gmail,omitempty"`
	GCal    string `json:"gcal,omitempty"`
	GSheets string `json:"gsheets,omitempty"`
}

// allEmpty short-circuits the prompt-injection branch when the user
// hasn't customised any per-connector instructions.
func (c ConnectorPrompts) allEmpty() bool {
	return c.Slack == "" && c.Clickup == "" && c.GDrive == "" &&
		c.Gmail == "" && c.GCal == "" && c.GSheets == ""
}

// Runner is the public entry point combining MCP fan-out + Claude summarize
// + rule-based fallback + final Briefing assembly.
type Runner struct {
	Orchestrator *Orchestrator
	Summarizer   *ClaudeRunner // may be nil → always uses fallback
}

// Run fetches raw data, summarizes via Claude (with fallback), and assembles
// the final Briefing for storage / rendering.
func (r *Runner) Run(ctx context.Context, accountNumber int) (*Briefing, error) {
	raw := r.Orchestrator.Fetch(ctx, accountNumber)
	today := time.Now()

	userPrompt := loadUserPrompt()
	connectorPrompts := loadConnectorPrompts()

	var payload *BriefingPayload
	if r.Summarizer != nil {
		p, err := r.Summarizer.Summarize(ctx, buildPrompt(raw, today, userPrompt, connectorPrompts))
		if err == nil {
			payload = p
		}
	}
	if payload == nil {
		payload = FallbackRank(raw, today)
	}

	return assembleBriefing(payload, raw, today), nil
}

// loadUserPrompt reads the user-authored markdown the widget Settings UI
// persists. Empty / missing file is treated as "no extra context" — the
// runner falls back to the stock prompt.
func loadUserPrompt() string {
	bytes, err := os.ReadFile(adapter.BriefingUserPromptFile())
	if err != nil {
		return ""
	}
	return string(bytes)
}

// loadConnectorPrompts decodes the per-MCP-source markdown overrides the
// widget Settings UI persists. Returns a zero ConnectorPrompts on any
// read / decode failure — the runner treats that as "no per-connector
// overrides" and falls through with the stock prompt.
func loadConnectorPrompts() ConnectorPrompts {
	bytes, err := os.ReadFile(adapter.MCPConnectorPromptsFile())
	if err != nil {
		return ConnectorPrompts{}
	}
	var out ConnectorPrompts
	if err := json.Unmarshal(bytes, &out); err != nil {
		return ConnectorPrompts{}
	}
	return out
}

// assembleBriefing merges Claude/fallback payload with raw stats + IDs into
// the final on-disk Briefing.
func assembleBriefing(p *BriefingPayload, raw *RawSourceData, today time.Time) *Briefing {
	actions := make([]Action, len(p.Actions))
	stats := BriefingStats{Total: len(p.Actions)}
	for i, pa := range p.Actions {
		a := Action{
			ID:           deriveActionID(pa, i),
			Index:        i + 1,
			Priority:     pa.Priority,
			Title:        pa.Title,
			Source:       pa.Source,
			SourceMeta:   pa.SourceMeta,
			Context:      pa.Context,
			Deadline:     pa.Deadline,
			DeadlineHint: pa.DeadlineHint,
			DeadlineTone: pa.DeadlineTone,
			DeepLink:     pa.DeepLink,
		}
		actions[i] = a
		switch pa.Priority {
		case "urgent":
			stats.Urgent++
		case "important":
			stats.Important++
		}
	}

	calendar := make([]CalEvent, len(p.Calendar))
	for i, c := range p.Calendar {
		calendar[i] = CalEvent{
			Time:     c.Time,
			EndTime:  c.EndTime,
			State:    c.State,
			Title:    c.Title,
			Subtitle: c.Subtitle,
			Flag:     c.Flag,
		}
	}

	return &Briefing{
		SchemaVersion: SchemaVersion,
		Date:          today.Format("2006-01-02"),
		GeneratedAt:   time.Now().UTC(),
		Hero: Hero{
			Eyebrow:     p.Hero.Eyebrow,
			Title:       p.Hero.Title,
			FocusBadge:  p.Hero.FocusBadge,
			FocusBody:   p.Hero.FocusBody,
			CountNumber: p.Hero.CountNumber,
			CountLabel:  p.Hero.CountLabel,
		},
		Actions:       actions,
		Calendar:      calendar,
		Stats:         stats,
		SourcesHealth: raw.Health,
	}
}

// deriveActionID produces a stable hash from action content so a 2nd run on
// the same day re-uses the same ID for unchanged items (preserves done state).
func deriveActionID(a PayloadAction, idx int) string {
	h := sha1.New()
	fmt.Fprintf(h, "%s\x00%s\x00%s\x00%d", a.Source, a.Title, a.Deadline, idx)
	return hex.EncodeToString(h.Sum(nil))[:12]
}
