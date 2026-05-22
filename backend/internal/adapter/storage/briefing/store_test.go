package briefingstore

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/usecase/briefing"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	return NewAt(t.TempDir())
}

func sampleBriefing(date string) *briefing.Briefing {
	return &briefing.Briefing{
		SchemaVersion: briefing.SchemaVersion,
		Date:          date,
		GeneratedAt:   time.Now().UTC(),
		Hero: briefing.Hero{
			Eyebrow: "Hôm nay bạn cần làm",
			Title:   "Một việc đang chờ.",
		},
		Actions: []briefing.Action{
			{ID: "a1", Index: 1, Priority: "urgent", Title: "Reply CTO"},
		},
		SourcesHealth: map[string]string{"gmail": "ok"},
	}
}

func TestSaveLoadRoundTrip(t *testing.T) {
	store := newTestStore(t)
	b := sampleBriefing("2026-05-21")
	if err := store.Save(b); err != nil {
		t.Fatalf("save: %v", err)
	}
	got, err := store.Load("2026-05-21")
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if got.Date != b.Date || len(got.Actions) != len(b.Actions) {
		t.Errorf("round-trip mismatch: %+v vs %+v", got, b)
	}
}

func TestLoadMissingReturnsNotFound(t *testing.T) {
	store := newTestStore(t)
	if _, err := store.Load("1999-01-01"); err != ErrNotFound {
		t.Errorf("want ErrNotFound, got %v", err)
	}
}

func TestPruneRetention(t *testing.T) {
	store := newTestStore(t)
	old := sampleBriefing("2020-01-01")
	cur := sampleBriefing(time.Now().Format("2006-01-02"))
	_ = store.Save(old)
	_ = store.Save(cur)

	n, err := store.Prune(30)
	if err != nil {
		t.Fatalf("prune: %v", err)
	}
	if n != 1 {
		t.Errorf("pruned %d, want 1", n)
	}
	if _, err := store.Load(old.Date); err != ErrNotFound {
		t.Errorf("old briefing should be gone")
	}
}

func TestToggleAction(t *testing.T) {
	store := newTestStore(t)
	b := sampleBriefing("2026-05-21")
	_ = store.Save(b)

	if err := store.ToggleAction("2026-05-21", "a1", true); err != nil {
		t.Fatalf("toggle: %v", err)
	}
	got, _ := store.Load("2026-05-21")
	if !got.Actions[0].Done {
		t.Errorf("toggle did not persist")
	}
}

func TestListDatesSorted(t *testing.T) {
	store := newTestStore(t)
	for _, d := range []string{"2026-05-21", "2026-05-22", "2026-05-20"} {
		_ = store.Save(sampleBriefing(d))
	}
	// Drop a stray file to ensure the .json gate filters correctly.
	_ = os.WriteFile(filepath.Join(store.dir, "ignore.txt"), []byte("x"), 0o600)

	dates, err := store.ListDates()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	want := []string{"2026-05-22", "2026-05-21", "2026-05-20"}
	if len(dates) != len(want) {
		t.Fatalf("len mismatch: %v", dates)
	}
	for i, d := range want {
		if dates[i] != d {
			t.Errorf("[%d] = %s, want %s", i, dates[i], d)
		}
	}
}
