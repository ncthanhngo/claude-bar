package briefing

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"time"
)

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

	var payload *BriefingPayload
	if r.Summarizer != nil {
		p, err := r.Summarizer.Summarize(ctx, buildPrompt(raw, today))
		if err == nil {
			payload = p
		}
	}
	if payload == nil {
		payload = FallbackRank(raw, today)
	}

	return assembleBriefing(payload, raw, today), nil
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
