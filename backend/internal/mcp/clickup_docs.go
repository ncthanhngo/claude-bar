package mcp

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"

	mcpgo "github.com/mark3labs/mcp-go/mcp"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// clickupDocsAPIBase is the ClickUp Docs (v3) API root. It is a different
// base from the v2 task API (clickupAPIBase) — Docs only exist on v3. Kept
// as a package var (not a const) so tests can point it at an httptest server,
// mirroring how clickup_tools_test.go swaps clickupAPIBase.
var clickupDocsAPIBase = "https://api.clickup.com/api/v3"

// clickupDocPageRe matches the page portion of a ClickUp Doc URL:
//
//	https://app.clickup.com/{workspace}/v/dc/{docId}/{pageId}
//
// IDs are NOT purely numeric (e.g. "3m5v4-218736"), so the segments are
// matched as "anything but a slash" rather than digits. The page segment is
// optional — a doc-only URL (…/v/dc/{docId}) selects the whole doc.
var clickupDocPageRe = regexp.MustCompile(`^/([^/]+)/v/dc/([^/]+)(?:/([^/]+))?/?$`)

// clickupDocRef is the parsed coordinates of a ClickUp Doc (and optional page).
type clickupDocRef struct {
	WorkspaceID string
	DocID       string
	PageID      string // empty ⇒ caller wants every page of the doc
}

// parseClickUpDocURL extracts {workspace, doc, page} from a ClickUp Doc URL of
// the form https://app.clickup.com/{workspace}/v/dc/{docId}/{pageId}. Matching
// is anchored on the URL path structure (after url.Parse) so a query string or
// fragment on the input can never leak into the returned IDs.
func parseClickUpDocURL(raw string) (clickupDocRef, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return clickupDocRef{}, fmt.Errorf("empty url")
	}
	u, err := url.Parse(raw)
	if err != nil {
		return clickupDocRef{}, fmt.Errorf("parse url: %w", err)
	}
	m := clickupDocPageRe.FindStringSubmatch(u.Path)
	if m == nil {
		return clickupDocRef{}, fmt.Errorf("not a ClickUp doc URL (expected …/{workspace}/v/dc/{docId}/{pageId}): %s", raw)
	}
	return clickupDocRef{WorkspaceID: m[1], DocID: m[2], PageID: m[3]}, nil
}

// clickupDocPagesURL builds the v3 request URL for reading doc pages. The query
// string is assembled literally rather than via url.Values.Encode() on purpose:
// the content_format value "text/md" contains a slash that QueryEscape would
// turn into "text%2Fmd". ClickUp expects the literal "text/md", and
// http.NewRequestWithContext preserves the raw query verbatim on the wire.
func clickupDocPagesURL(base string, ref clickupDocRef) string {
	prefix := base + "/workspaces/" + ref.WorkspaceID + "/docs/" + ref.DocID + "/pages"
	if ref.PageID != "" {
		return prefix + "/" + ref.PageID + "?content_format=text/md"
	}
	// Whole doc: -1 returns the full nesting depth of pages.
	return prefix + "?content_format=text/md&max_page_depth=-1"
}

// clickupCallV3 performs a read against the ClickUp v3 API. It mirrors
// clickupCall's auth + error handling (raw Authorization token, no Bearer;
// Accept JSON; gateway User-Agent; Redact on error bodies) but takes a fully
// built URL so the caller controls the literal query string. The v2 callers
// are intentionally left untouched.
func (g *Gateway) clickupCallV3(ctx context.Context, token, fullURL string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fullURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", token) // raw token, no Bearer prefix
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", g.UserAgent)

	resp, err := g.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("clickup http: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("clickup read: %w", err)
	}
	if resp.StatusCode/100 != 2 {
		return body, fmt.Errorf("clickup http %d: %s", resp.StatusCode, Redact(strings.TrimSpace(string(body))))
	}
	return body, nil
}

// clickupGetDoc reads a ClickUp Doc's page content as markdown. It accepts
// either a full ClickUp doc URL or explicit workspace_id + doc_id (+ optional
// page_id). With a page it returns that single page; without one it returns
// every page of the doc.
func (g *Gateway) clickupGetDoc(ctx context.Context, req mcpgo.CallToolRequest) (*mcpgo.CallToolResult, error) {
	ref, err := resolveClickUpDocRef(req)
	if err != nil {
		return toolErrorf("%v", err), nil
	}

	cc, err := g.Resolver.Resolve(ctx, domain.MCPServiceClickUp)
	if err != nil {
		return toolErrorForResolve(err), nil
	}

	body, err := g.clickupCallV3(ctx, cc.Payload, clickupDocPagesURL(clickupDocsAPIBase, ref))
	if err != nil {
		return toolErrorf("clickup get doc: %v", err), nil
	}
	// The v3 endpoint returns markdown-bearing JSON: an object for a single
	// page, a top-level array for all pages. Forward the raw payload verbatim
	// so neither shape is lost to a mismatched struct target.
	return mcpgo.NewToolResultText(string(body)), nil
}

// resolveClickUpDocRef turns the tool's inputs into a doc reference. Callers
// must supply exactly one of: a `url`, or `workspace_id` + `doc_id`. This
// mirrors the exactly-one-of validation in clickupListLists.
func resolveClickUpDocRef(req mcpgo.CallToolRequest) (clickupDocRef, error) {
	rawURL := strings.TrimSpace(req.GetString("url", ""))
	workspaceID := strings.TrimSpace(req.GetString("workspace_id", ""))
	docID := strings.TrimSpace(req.GetString("doc_id", ""))
	pageID := strings.TrimSpace(req.GetString("page_id", ""))

	hasExplicit := workspaceID != "" || docID != ""
	if rawURL == "" && !hasExplicit {
		return clickupDocRef{}, fmt.Errorf("provide either url or workspace_id + doc_id")
	}
	if rawURL != "" && hasExplicit {
		return clickupDocRef{}, fmt.Errorf("provide either url or workspace_id + doc_id, not both")
	}

	if rawURL != "" {
		return parseClickUpDocURL(rawURL)
	}
	if workspaceID == "" || docID == "" {
		return clickupDocRef{}, fmt.Errorf("workspace_id and doc_id are both required when url is omitted")
	}
	return clickupDocRef{WorkspaceID: workspaceID, DocID: docID, PageID: pageID}, nil
}
