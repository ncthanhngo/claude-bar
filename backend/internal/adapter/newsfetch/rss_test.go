package newsfetch

import (
	"strings"
	"testing"

	"github.com/mmcdole/gofeed"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// fixtureRSS is a captured (hand-written but representative) RSS 2.0
// document: one item with an image enclosure + HTML-laden description, one
// without an image. Parsing happens fully offline via gofeed.ParseString —
// no network in this test.
const fixtureRSS = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
<channel>
  <title>Test Feed</title>
  <link>https://example.com</link>
  <description>A test feed</description>
  <item>
    <title>First Item</title>
    <link>https://example.com/first</link>
    <description>&lt;p&gt;Hello &lt;b&gt;world&lt;/b&gt;&lt;/p&gt;</description>
    <pubDate>Mon, 02 Jan 2006 15:04:05 GMT</pubDate>
    <enclosure url="https://example.com/first.jpg" type="image/jpeg" length="1000"/>
  </item>
  <item>
    <title>Second Item</title>
    <link>https://example.com/second</link>
    <description>No image here.</description>
  </item>
  <item>
    <title>No Link Item</title>
    <description>Should be skipped — no link.</description>
  </item>
</channel>
</rss>`

func TestNormalizeFeedItems(t *testing.T) {
	parsed, err := gofeed.NewParser().ParseString(fixtureRSS)
	if err != nil {
		t.Fatalf("parse fixture: %v", err)
	}

	items := normalizeFeedItems(parsed, port.Feed{Label: "Test Feed"})
	if len(items) != 2 {
		t.Fatalf("want 2 items (link-less item skipped), got %d", len(items))
	}

	first := items[0]
	if first.Title != "First Item" {
		t.Errorf("title = %q, want %q", first.Title, "First Item")
	}
	if first.OriginalURL != "https://example.com/first" {
		t.Errorf("originalURL = %q", first.OriginalURL)
	}
	if first.ImageURL != "https://example.com/first.jpg" {
		t.Errorf("imageURL = %q, want the enclosure image", first.ImageURL)
	}
	if first.PublishedAt == "" {
		t.Error("expected non-empty publishedAt")
	}
	if first.Description == "" || strings.Contains(first.Description, "<") {
		t.Errorf("description not cleaned of HTML: %q", first.Description)
	}
	if first.SourceLabel != "Test Feed" {
		t.Errorf("sourceLabel = %q, want feed.Label to win", first.SourceLabel)
	}
	wantFavicon := "https://www.google.com/s2/favicons?domain=example.com&sz=64"
	if first.SourceFaviconURL != wantFavicon {
		t.Errorf("favicon = %q, want %q", first.SourceFaviconURL, wantFavicon)
	}
	if first.ID == "" {
		t.Error("expected non-empty stable id")
	}

	second := items[1]
	if second.ImageURL != "" {
		t.Errorf("expected no image for second item, got %q", second.ImageURL)
	}
}

func TestNormalizeFeedItems_LabelFallsBackToFeedTitle(t *testing.T) {
	parsed, err := gofeed.NewParser().ParseString(fixtureRSS)
	if err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	items := normalizeFeedItems(parsed, port.Feed{}) // no configured label
	if len(items) == 0 {
		t.Fatal("expected items")
	}
	if items[0].SourceLabel != "Test Feed" {
		t.Errorf("sourceLabel = %q, want parsed feed title fallback", items[0].SourceLabel)
	}
}

func TestStableID_DeterministicAndUnique(t *testing.T) {
	a := stableID("https://example.com/a")
	b := stableID("https://example.com/a")
	c := stableID("https://example.com/b")
	if a != b {
		t.Errorf("stableID not deterministic: %q vs %q", a, b)
	}
	if a == c {
		t.Errorf("stableID collided for distinct URLs: %q", a)
	}
	if a == "" {
		t.Error("expected non-empty id")
	}
}
