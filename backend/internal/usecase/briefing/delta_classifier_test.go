package briefing

import "testing"

func b(actions []Action, events []CalEvent, health map[string]string) *Briefing {
	return &Briefing{Actions: actions, Calendar: events, SourcesHealth: health}
}

func TestClassifyDeltaNewUrgentActionIsCritical(t *testing.T) {
	prev := b(nil, nil, nil)
	curr := b([]Action{
		{ID: "a1", Title: "URGENT: prod down", Priority: "urgent", Source: "slack"},
	}, nil, nil)
	d := ClassifyDelta(prev, curr)
	if len(d) != 1 {
		t.Fatalf("want 1 delta, got %d (%+v)", len(d), d)
	}
	if d[0].Tier != TierCritical {
		t.Errorf("urgent action should be Critical, got %v", d[0].Tier)
	}
}

func TestClassifyDeltaUrgentByKeywordEvenWithoutFlag(t *testing.T) {
	prev := b(nil, nil, nil)
	curr := b([]Action{
		{ID: "a1", Title: "Incident on payments service", Priority: "important", Source: "slack"},
	}, nil, nil)
	d := ClassifyDelta(prev, curr)
	if d[0].Tier != TierCritical {
		t.Errorf("incident keyword should escalate to Critical, got %v", d[0].Tier)
	}
}

func TestClassifyDeltaNormalNewIsMaterial(t *testing.T) {
	prev := b(nil, nil, nil)
	curr := b([]Action{
		{ID: "a1", Title: "Review PR #42", Priority: "normal", Source: "github"},
	}, nil, nil)
	d := ClassifyDelta(prev, curr)
	if d[0].Tier != TierMaterial {
		t.Errorf("normal-priority new action should be Material, got %v", d[0].Tier)
	}
}

func TestClassifyDeltaPriorityBumpToUrgent(t *testing.T) {
	prev := b([]Action{{ID: "a1", Priority: "important", Title: "x"}}, nil, nil)
	curr := b([]Action{{ID: "a1", Priority: "urgent", Title: "x"}}, nil, nil)
	d := ClassifyDelta(prev, curr)
	if len(d) != 1 || d[0].Kind != "action.priority-bump" || d[0].Tier != TierCritical {
		t.Fatalf("priority bump → %+v", d)
	}
}

func TestClassifyDeltaCalendarNowFires(t *testing.T) {
	prev := b(nil, []CalEvent{{Title: "Demo", Time: "14:00", State: "next"}}, nil)
	curr := b(nil, []CalEvent{{Title: "Demo", Time: "14:00", State: "now"}}, nil)
	d := ClassifyDelta(prev, curr)
	if len(d) != 1 || d[0].Tier != TierCritical {
		t.Fatalf("event going to 'now' should be Critical: %+v", d)
	}
}

func TestClassifyDeltaSourceHealthRegression(t *testing.T) {
	prev := b(nil, nil, map[string]string{"gmail": "ok"})
	curr := b(nil, nil, map[string]string{"gmail": "expired"})
	d := ClassifyDelta(prev, curr)
	if len(d) != 1 || d[0].Tier != TierCritical {
		t.Fatalf("source ok → expired should be Critical: %+v", d)
	}
}

func TestClassifyDeltaNoChangeReturnsEmpty(t *testing.T) {
	a := b([]Action{{ID: "a1", Priority: "normal"}}, nil, nil)
	d := ClassifyDelta(a, a)
	if len(d) != 0 {
		t.Errorf("identical briefings should produce no deltas, got %+v", d)
	}
}
