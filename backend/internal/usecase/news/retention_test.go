package news

import (
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

func TestMergeRetain_DropsItemsOlderThan30Days(t *testing.T) {
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC)
	prev := []port.NewsItem{
		{OriginalURL: "https://a.example/old", PublishedAt: now.Add(-40 * 24 * time.Hour).Format(time.RFC3339)},
		{OriginalURL: "https://a.example/recent", PublishedAt: now.Add(-5 * 24 * time.Hour).Format(time.RFC3339)},
	}

	merged, _ := MergeRetain(prev, nil, map[string]string{}, now)
	if len(merged) != 1 {
		t.Fatalf("want 1 surviving item, got %d: %+v", len(merged), merged)
	}
	if merged[0].OriginalURL != "https://a.example/recent" {
		t.Errorf("expected the recent item to survive, got %+v", merged[0])
	}
}

func TestMergeRetain_KeepsItemsWithin30Days(t *testing.T) {
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC)
	prev := []port.NewsItem{
		{OriginalURL: "https://a.example/29days", PublishedAt: now.Add(-29 * 24 * time.Hour).Format(time.RFC3339)},
	}
	merged, _ := MergeRetain(prev, nil, map[string]string{}, now)
	if len(merged) != 1 {
		t.Fatalf("want the 29-day-old item to survive, got %+v", merged)
	}
}

func TestMergeRetain_MergesFreshIntoPrevAndDedupesByURL(t *testing.T) {
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC)
	prev := []port.NewsItem{
		{OriginalURL: "https://a.example/1", Title: "Old title", PublishedAt: now.Add(-1 * time.Hour).Format(time.RFC3339)},
	}
	fresh := []port.NewsItem{
		{OriginalURL: "https://a.example/1", Title: "New title", PublishedAt: now.Format(time.RFC3339)},
		{OriginalURL: "https://a.example/2", Title: "Brand new item", PublishedAt: now.Format(time.RFC3339)},
	}

	merged, _ := MergeRetain(prev, fresh, map[string]string{}, now)
	if len(merged) != 2 {
		t.Fatalf("want 2 deduped items, got %d: %+v", len(merged), merged)
	}
	byURL := map[string]port.NewsItem{}
	for _, it := range merged {
		byURL[it.OriginalURL] = it
	}
	if byURL["https://a.example/1"].Title != "New title" {
		t.Errorf("expected the fresh record to win for a duplicate URL, got %+v", byURL["https://a.example/1"])
	}
}

func TestMergeRetain_BackfillsEnrichmentFieldsFromOldWhenFreshIsThin(t *testing.T) {
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC)
	prev := []port.NewsItem{
		{OriginalURL: "https://a.example/1", TitleVI: "Tiêu đề cũ", ImageURL: "https://img/old.jpg", PublishedAt: now.Add(-2 * time.Hour).Format(time.RFC3339)},
	}
	// Fresh refetch that failed to summarise/resolve an image this round
	// (e.g. AI call timed out) must not erase the previously-enriched data.
	fresh := []port.NewsItem{
		{OriginalURL: "https://a.example/1", Title: "English title", PublishedAt: now.Format(time.RFC3339)},
	}

	merged, _ := MergeRetain(prev, fresh, map[string]string{}, now)
	if len(merged) != 1 {
		t.Fatalf("want 1 item, got %+v", merged)
	}
	if merged[0].TitleVI != "Tiêu đề cũ" || merged[0].ImageURL != "https://img/old.jpg" {
		t.Errorf("expected enrichment fields backfilled from the old record, got %+v", merged[0])
	}
}

func TestMergeRetain_FallsBackToFirstSeenWhenPublishedAtEmpty(t *testing.T) {
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC)
	prev := []port.NewsItem{{OriginalURL: "https://a.example/no-date"}} // no PublishedAt
	firstSeen := map[string]string{"https://a.example/no-date": now.Add(-40 * 24 * time.Hour).Format(time.RFC3339)}

	merged, nextFirstSeen := MergeRetain(prev, nil, firstSeen, now)
	if len(merged) != 0 {
		t.Errorf("expected the item to be pruned via its 40-day-old first-seen timestamp, got %+v", merged)
	}
	if _, stillTracked := nextFirstSeen["https://a.example/no-date"]; stillTracked {
		t.Error("pruned item's first-seen entry should be dropped, not carried forward")
	}
}

func TestMergeRetain_StampsFirstSeenOnFirstAppearance(t *testing.T) {
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC)
	fresh := []port.NewsItem{{OriginalURL: "https://a.example/brand-new"}} // no PublishedAt, never seen before

	merged, nextFirstSeen := MergeRetain(nil, fresh, map[string]string{}, now)
	if len(merged) != 1 {
		t.Fatalf("a never-before-seen item with no PublishedAt must not be pruned on its first sighting, got %+v", merged)
	}
	if nextFirstSeen["https://a.example/brand-new"] != now.UTC().Format(time.RFC3339) {
		t.Errorf("expected first-seen stamped to now, got %+v", nextFirstSeen)
	}
}

func TestMergeRetain_EmptyInputsProduceEmptySlicesNotNil(t *testing.T) {
	merged, nextFirstSeen := MergeRetain(nil, nil, map[string]string{}, time.Now())
	if merged == nil {
		t.Error("merged items should be an empty slice, not nil")
	}
	if nextFirstSeen == nil {
		t.Error("nextFirstSeen should be an empty map, not nil")
	}
}
