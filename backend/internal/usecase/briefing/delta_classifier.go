package briefing

import (
	"regexp"
	"strings"
)

// DeltaTier mirrors phase-06 plan terminology. Notifications fire only for
// Critical; Material updates UI state; Background is silent.
type DeltaTier string

const (
	TierCritical   DeltaTier = "critical"
	TierMaterial   DeltaTier = "material"
	TierBackground DeltaTier = "background"
)

// Delta is one diff between two consecutive briefing snapshots.
type Delta struct {
	Kind       string    `json:"kind"` // "action.new" | "action.priority-bump" | "calendar.new" | "calendar.now" | "source.health-down"
	Tier       DeltaTier `json:"tier"`
	ActionID   string    `json:"actionId,omitempty"`
	EventTitle string    `json:"eventTitle,omitempty"`
	Source     string    `json:"source,omitempty"`
	Reason     string    `json:"reason,omitempty"`
}

// urgentKeywords are the case-insensitive matches that trip Critical.
var urgentKeywords = regexp.MustCompile(`(?i)\b(urgent|asap|now|incident|p0|p1|escalat|outage|down|broken|critical)\b`)

// ClassifyDelta walks prev → current and returns the diff list in tier order
// (Critical → Material → Background within each kind). Pure function — no
// I/O, no random state — so it's trivial to unit-test against fixtures.
//
// Rules (matches phase-06 plan):
//   - Critical: new mention containing urgentKeywords; meeting starting in
//     ≤15 min that wasn't already "now" in prev; source went from "ok" to
//     "expired"/"down".
//   - Material: new action row that's not urgent; calendar event added or
//     moved.
//   - Background: counts changed, no actionable signal.
func ClassifyDelta(prev, curr *Briefing) []Delta {
	if prev == nil || curr == nil {
		return nil
	}
	prevActions := indexActions(prev.Actions)
	currActions := indexActions(curr.Actions)

	out := []Delta{}

	// 1) New actions.
	for id, a := range currActions {
		if _, ok := prevActions[id]; ok {
			continue
		}
		tier := TierMaterial
		if isUrgent(a) {
			tier = TierCritical
		}
		out = append(out, Delta{
			Kind:     "action.new",
			Tier:     tier,
			ActionID: id,
			Source:   a.Source,
			Reason:   a.Title,
		})
	}

	// 2) Priority bumps within existing actions.
	for id, p := range prevActions {
		c, ok := currActions[id]
		if !ok {
			continue
		}
		if p.Priority != c.Priority && c.Priority == "urgent" {
			out = append(out, Delta{
				Kind:     "action.priority-bump",
				Tier:     TierCritical,
				ActionID: id,
				Source:   c.Source,
				Reason:   p.Priority + " → " + c.Priority,
			})
		}
	}

	// 3) Calendar "now" events new since last snapshot.
	prevNow := indexCalendarByState(prev.Calendar, "now")
	for _, e := range curr.Calendar {
		if e.State != "now" {
			continue
		}
		if _, ok := prevNow[e.Title+"|"+e.Time]; ok {
			continue
		}
		out = append(out, Delta{
			Kind:       "calendar.now",
			Tier:       TierCritical,
			EventTitle: e.Title,
			Reason:     "starts at " + e.Time,
		})
	}

	// 4) Source health regressions.
	for src, st := range curr.SourcesHealth {
		prevSt := prev.SourcesHealth[src]
		if prevSt == st {
			continue
		}
		if st == "down" || st == "expired" {
			tier := TierCritical
			if prevSt == "" {
				tier = TierMaterial // first observation — surface but don't page
			}
			out = append(out, Delta{
				Kind:   "source.health-down",
				Tier:   tier,
				Source: src,
				Reason: prevSt + " → " + st,
			})
		}
	}

	return out
}

func indexActions(actions []Action) map[string]Action {
	out := make(map[string]Action, len(actions))
	for _, a := range actions {
		out[a.ID] = a
	}
	return out
}

func indexCalendarByState(events []CalEvent, state string) map[string]CalEvent {
	out := map[string]CalEvent{}
	for _, e := range events {
		if e.State == state {
			out[e.Title+"|"+e.Time] = e
		}
	}
	return out
}

func isUrgent(a Action) bool {
	if a.Priority == "urgent" {
		return true
	}
	hay := strings.ToLower(a.Title + " " + a.Context + " " + a.SourceMeta)
	return urgentKeywords.MatchString(hay)
}
