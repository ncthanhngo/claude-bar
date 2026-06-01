package mcp

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestParseClickUpDocURL_PageURL is the load-bearing discriminator: the exact
// doc URL that cb_clickup_get_task fails on (it isn't a task) must parse into
// the three coordinates the v3 Docs API needs. IDs are not numeric.
func TestParseClickUpDocURL_PageURL(t *testing.T) {
	ref, err := parseClickUpDocURL("https://app.clickup.com/3807076/v/dc/3m5v4-218736/3m5v4-315356")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if ref.WorkspaceID != "3807076" {
		t.Errorf("workspace_id = %q, want 3807076", ref.WorkspaceID)
	}
	if ref.DocID != "3m5v4-218736" {
		t.Errorf("doc_id = %q, want 3m5v4-218736", ref.DocID)
	}
	if ref.PageID != "3m5v4-315356" {
		t.Errorf("page_id = %q, want 3m5v4-315356", ref.PageID)
	}
}

// TestParseClickUpDocURL_DocOnly: a URL with no page segment leaves PageID
// empty so the caller fetches the whole doc.
func TestParseClickUpDocURL_DocOnly(t *testing.T) {
	ref, err := parseClickUpDocURL("https://app.clickup.com/3807076/v/dc/3m5v4-218736")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if ref.WorkspaceID != "3807076" || ref.DocID != "3m5v4-218736" || ref.PageID != "" {
		t.Errorf("unexpected ref %+v", ref)
	}
}

// TestParseClickUpDocURL_IgnoresQueryAndFragment: matching is anchored on the
// URL path, so a trailing ?query or #fragment must not leak into page_id.
func TestParseClickUpDocURL_IgnoresQueryAndFragment(t *testing.T) {
	ref, err := parseClickUpDocURL("https://app.clickup.com/3807076/v/dc/3m5v4-218736/3m5v4-315356?block=abc#heading")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if ref.PageID != "3m5v4-315356" {
		t.Errorf("page_id = %q, want clean 3m5v4-315356", ref.PageID)
	}
}

// TestParseClickUpDocURL_Rejects: a task URL (or anything not matching the
// /v/dc/ doc shape) must error rather than silently mis-parse.
func TestParseClickUpDocURL_Rejects(t *testing.T) {
	for _, raw := range []string{
		"https://app.clickup.com/t/3807076/ABC-123",
		"https://app.clickup.com/3807076/v/li/901234",
		"",
	} {
		if _, err := parseClickUpDocURL(raw); err == nil {
			t.Errorf("expected error for %q, got nil", raw)
		}
	}
}

// TestClickUpDocPagesURL_SinglePage pins the exact v3 request URL for the
// failing-case input. The content_format slash must survive literally —
// url.Values.Encode() would turn it into text%2Fmd, which this asserts against.
func TestClickUpDocPagesURL_SinglePage(t *testing.T) {
	ref := clickupDocRef{WorkspaceID: "3807076", DocID: "3m5v4-218736", PageID: "3m5v4-315356"}
	got := clickupDocPagesURL("https://api.clickup.com/api/v3", ref)
	want := "https://api.clickup.com/api/v3/workspaces/3807076/docs/3m5v4-218736/pages/3m5v4-315356?content_format=text/md"
	if got != want {
		t.Errorf("single-page URL\n got %q\nwant %q", got, want)
	}
}

// TestClickUpDocPagesURL_AllPages pins the whole-doc URL (no page) including
// the max_page_depth=-1 param and the literal text/md.
func TestClickUpDocPagesURL_AllPages(t *testing.T) {
	ref := clickupDocRef{WorkspaceID: "3807076", DocID: "3m5v4-218736"}
	got := clickupDocPagesURL("https://api.clickup.com/api/v3", ref)
	want := "https://api.clickup.com/api/v3/workspaces/3807076/docs/3m5v4-218736/pages?content_format=text/md&max_page_depth=-1"
	if got != want {
		t.Errorf("all-pages URL\n got %q\nwant %q", got, want)
	}
}

// TestResolveClickUpDocRef_Validation mirrors the exactly-one-of contract:
// neither input → error; both url and explicit IDs → error.
func TestResolveClickUpDocRef_Validation(t *testing.T) {
	if _, err := resolveClickUpDocRef(newCallRequest(map[string]any{})); err == nil {
		t.Error("expected error when no inputs given")
	}
	if _, err := resolveClickUpDocRef(newCallRequest(map[string]any{
		"url":          "https://app.clickup.com/3807076/v/dc/3m5v4-218736/3m5v4-315356",
		"workspace_id": "3807076",
	})); err == nil {
		t.Error("expected error when both url and explicit IDs given")
	}
	// workspace_id without doc_id is incomplete.
	if _, err := resolveClickUpDocRef(newCallRequest(map[string]any{"workspace_id": "3807076"})); err == nil {
		t.Error("expected error when doc_id is missing")
	}
}

// TestResolveClickUpDocRef_Explicit: explicit IDs route straight through,
// preserving an optional page_id.
func TestResolveClickUpDocRef_Explicit(t *testing.T) {
	ref, err := resolveClickUpDocRef(newCallRequest(map[string]any{
		"workspace_id": "3807076",
		"doc_id":       "3m5v4-218736",
		"page_id":      "3m5v4-315356",
	}))
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if ref != (clickupDocRef{WorkspaceID: "3807076", DocID: "3m5v4-218736", PageID: "3m5v4-315356"}) {
		t.Errorf("unexpected ref %+v", ref)
	}
}

// TestClickUpGetDoc_RoundTrip drives the full handler against an httptest
// server (base var swapped just like TestClickUpHierarchyPaths). It asserts
// the request reaches the v3 pages path with the raw token (no Bearer), that
// content_format=text/md arrives un-escaped on the wire, and that the markdown
// body is forwarded verbatim.
func TestClickUpGetDoc_RoundTrip(t *testing.T) {
	var sawAuth, sawPath, sawFormat string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawAuth = r.Header.Get("Authorization")
		sawPath = r.URL.Path
		// r.URL.Query() decodes %2F back to "/", so reading the decoded
		// value proves text/md (slash intact) regardless of escaping.
		sawFormat = r.URL.Query().Get("content_format")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"3m5v4-315356","content":"# Hello\n\nworld"}`))
	}))
	defer srv.Close()

	oldBase := clickupDocsAPIBase
	clickupDocsAPIBase = srv.URL
	defer func() { clickupDocsAPIBase = oldBase }()

	gw := newClickUpTestGateway(srv.Client())
	res, err := gw.clickupGetDoc(context.Background(), newCallRequest(map[string]any{
		"url": "https://app.clickup.com/3807076/v/dc/3m5v4-218736/3m5v4-315356",
	}))
	if err != nil {
		t.Fatalf("handler err: %v", err)
	}
	if res == nil || res.IsError {
		t.Fatalf("unexpected tool error: %+v", res)
	}
	if strings.HasPrefix(sawAuth, "Bearer") {
		t.Errorf("ClickUp Authorization must be raw token, got %q", sawAuth)
	}
	if sawAuth != "pk_test" {
		t.Errorf("Authorization = %q, want raw pk_test", sawAuth)
	}
	if sawPath != "/workspaces/3807076/docs/3m5v4-218736/pages/3m5v4-315356" {
		t.Errorf("path = %q", sawPath)
	}
	if sawFormat != "text/md" {
		t.Errorf("content_format = %q, want text/md (slash intact)", sawFormat)
	}
	text := toolResultText(res)
	if !strings.Contains(text, "# Hello") {
		t.Errorf("doc markdown not forwarded; got %q", text)
	}
}
