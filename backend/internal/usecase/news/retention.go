package news

import (
	"sort"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// retentionWindow is the rolling feed window — items older than this (by
// PublishedAt, falling back to the persisted first-seen timestamp) are
// dropped from the snapshot on every fetch. The saved-bookmarks store
// (news/saved.json) is entirely separate and never consults this.
const retentionWindow = 30 * 24 * time.Hour

// MergeRetain merges freshly fetched items into the previously persisted
// set, deduping by OriginalURL (keeping the richer/newer record — see
// mergeNewsItem), then drops anything whose effective timestamp has aged
// past retentionWindow. Repos are NOT handled here — the contract treats
// them as a live trending view (latest fetch only, no accumulation), so the
// caller simply keeps the fresh fetch's repo list as-is.
//
// firstSeen is the persisted first-seen-timestamp map (RFC3339, keyed by
// OriginalURL); the returned map reflects only the surviving items — a
// pruned item's entry is dropped too, so the map never grows unbounded.
func MergeRetain(prevItems, freshItems []port.NewsItem, firstSeen map[string]string, now time.Time) (merged []port.NewsItem, nextFirstSeen map[string]string) {
	byURL := make(map[string]port.NewsItem, len(prevItems)+len(freshItems))
	for _, it := range prevItems {
		if it.OriginalURL == "" {
			continue
		}
		byURL[it.OriginalURL] = it
	}
	for _, it := range freshItems {
		if it.OriginalURL == "" {
			continue
		}
		if old, ok := byURL[it.OriginalURL]; ok {
			byURL[it.OriginalURL] = mergeNewsItem(old, it)
		} else {
			byURL[it.OriginalURL] = it
		}
	}

	cutoff := now.Add(-retentionWindow)
	merged = make([]port.NewsItem, 0, len(byURL))
	nextFirstSeen = make(map[string]string, len(byURL))
	for url, it := range byURL {
		seenAt, hadSeen := firstSeen[url]
		if !hadSeen {
			seenAt = now.UTC().Format(time.RFC3339)
		}
		if effectiveTimestamp(it, seenAt, now).Before(cutoff) {
			continue
		}
		merged = append(merged, it)
		nextFirstSeen[url] = seenAt
	}

	sort.Slice(merged, func(i, j int) bool { return merged[i].PublishedAt > merged[j].PublishedAt })
	return merged, nextFirstSeen
}

// mergeNewsItem keeps fresh (the newer fetch) as the base record and
// backfills any field it failed to (re-)populate — a missing image or a
// timed-out AI summarise call on this run must not regress an item that was
// already fully enriched by an earlier fetch.
func mergeNewsItem(old, fresh port.NewsItem) port.NewsItem {
	out := fresh
	if out.TitleVI == "" {
		out.TitleVI = old.TitleVI
	}
	if out.SummaryVI == "" {
		out.SummaryVI = old.SummaryVI
	}
	if out.FullVI == "" {
		out.FullVI = old.FullVI
	}
	if out.ImageURL == "" {
		out.ImageURL = old.ImageURL
	}
	if out.PublishedAt == "" {
		out.PublishedAt = old.PublishedAt
	}
	if out.Category == "" {
		out.Category = old.Category
	}
	return out
}

// effectiveTimestamp parses it.PublishedAt (RFC3339); if that's empty or
// unparseable, falls back to firstSeen; if that also fails to parse, falls
// back to now — never prune something with no timestamp information at all,
// safer than silently dropping it.
func effectiveTimestamp(it port.NewsItem, firstSeen string, now time.Time) time.Time {
	if t, err := time.Parse(time.RFC3339, it.PublishedAt); err == nil {
		return t
	}
	if t, err := time.Parse(time.RFC3339, firstSeen); err == nil {
		return t
	}
	return now
}
