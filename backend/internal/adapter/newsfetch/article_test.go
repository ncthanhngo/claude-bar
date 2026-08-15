package newsfetch

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const fixtureArticleHTML = `<!DOCTYPE html>
<html>
<head><title>Test Article Title</title>
<script>var x = "should not appear in body";</script>
<style>.foo { color: red; }</style>
</head>
<body>
<nav>Home | About | Contact</nav>
<header>Site Header Boilerplate</header>
<article>
  <p>First paragraph of the article, with some <b>bold</b> text.</p>
  <p>Second paragraph continues the story here.</p>
</article>
<footer>Copyright 2026 — should not appear</footer>
</body>
</html>`

func TestArticle_ExtractTitleAndBody(t *testing.T) {
	title := extractTitle(fixtureArticleHTML)
	if title != "Test Article Title" {
		t.Errorf("title = %q, want %q", title, "Test Article Title")
	}

	body := extractBody(fixtureArticleHTML)
	if !strings.Contains(body, "First paragraph of the article") {
		t.Errorf("body missing first paragraph: %q", body)
	}
	if !strings.Contains(body, "Second paragraph continues") {
		t.Errorf("body missing second paragraph: %q", body)
	}
	if strings.Contains(body, "\n\n") == false {
		t.Errorf("expected paragraphs joined by a blank line, got: %q", body)
	}
	for _, boilerplate := range []string{"should not appear in body", "color: red", "Home | About", "Site Header", "Copyright 2026"} {
		if strings.Contains(body, boilerplate) {
			t.Errorf("body leaked boilerplate %q: %q", boilerplate, body)
		}
	}
	if strings.Contains(body, "<b>") || strings.Contains(body, "</p>") {
		t.Errorf("body still contains HTML tags: %q", body)
	}
}

func TestArticle_ExtractBody_FallsBackToAllParagraphsWithoutArticleTag(t *testing.T) {
	noArticleTag := `<html><head><title>No Article Tag</title></head><body>
<div><p>Only paragraph on the page.</p></div>
</body></html>`
	body := extractBody(noArticleTag)
	if !strings.Contains(body, "Only paragraph on the page") {
		t.Errorf("expected fallback to page-wide <p> extraction, got: %q", body)
	}
}

func TestArticle_ExtractBody_FallsBackToWholePageWithoutParagraphTags(t *testing.T) {
	noParagraphs := `<html><body><div>Just plain text, no p tags at all.</div></body></html>`
	body := extractBody(noParagraphs)
	if !strings.Contains(body, "Just plain text, no p tags at all.") {
		t.Errorf("expected fallback to whole-page text, got: %q", body)
	}
}

func TestArticle_ExtractBody_CapsLength(t *testing.T) {
	long := strings.Repeat("word ", 3000) // ~15000 chars, well over the cap
	html := "<html><body><article><p>" + long + "</p></article></body></html>"
	body := extractBody(html)
	if len([]rune(body)) > maxArticleTextChars {
		t.Errorf("body length = %d, want <= %d", len([]rune(body)), maxArticleTextChars)
	}
}

func TestArticle_FetchArticle_ReturnsTitleAndBody(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(fixtureArticleHTML))
	}))
	defer srv.Close()

	a := NewArticle()
	title, body, err := a.FetchArticle(context.Background(), srv.URL)
	if err != nil {
		t.Fatalf("FetchArticle: %v", err)
	}
	if title != "Test Article Title" {
		t.Errorf("title = %q", title)
	}
	if !strings.Contains(body, "First paragraph") {
		t.Errorf("body = %q", body)
	}
}

func TestArticle_FetchArticle_ErrorsOnHTTPFailureStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	a := NewArticle()
	if _, _, err := a.FetchArticle(context.Background(), srv.URL); err == nil {
		t.Fatal("expected error for a 404 response")
	}
}

func TestArticle_FetchArticle_ErrorsWhenNoReadableText(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`<html><head><title>Empty</title></head><body></body></html>`))
	}))
	defer srv.Close()

	a := NewArticle()
	if _, _, err := a.FetchArticle(context.Background(), srv.URL); err == nil {
		t.Fatal("expected error when the page has no extractable body text")
	}
}
