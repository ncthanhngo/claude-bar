package mcp

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	mcpgo "github.com/mark3labs/mcp-go/mcp"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

func newCallRequest(args map[string]any) mcpgo.CallToolRequest {
	return mcpgo.CallToolRequest{Params: mcpgo.CallToolParams{Arguments: args}}
}

func newClickUpTestGateway(client *http.Client) *Gateway {
	gw := newTestGateway()
	gw.HTTP = client
	reg := domain.NewRegistry()
	reg.ActiveAccountNumber = 1
	reg.Sequence = []int{1}
	reg.Accounts[1] = &domain.Account{
		Number: 1,
		Email:  "clickup@example.com",
		MCPConnectors: domain.AccountConnectors{
			domain.MCPServiceClickUp: &domain.MCPConnector{Enabled: true},
		},
	}
	gw.Resolver = &Resolver{
		Registry: &fakeRegistry{reg: reg},
		Secrets:  fakeSecrets{key(1, domain.MCPServiceClickUp): "pk_test"},
	}
	return gw
}

func TestClickUpCallSendsRawTokenAndDecodes(t *testing.T) {
	var sawAuth, sawPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawAuth = r.Header.Get("Authorization")
		sawPath = r.URL.Path
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"tasks":[{"id":"abc","name":"task one"}]}`))
	}))
	defer srv.Close()

	gw := newTestGateway()
	gw.HTTP = srv.Client()

	resp, err := clickupCallAt(context.Background(), gw, srv.URL+"/list/123/task", "pk_1_AAAA")
	if err != nil {
		t.Fatalf("call: %v", err)
	}
	var out struct {
		Tasks []map[string]any `json:"tasks"`
	}
	if err := json.Unmarshal(resp, &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(out.Tasks) != 1 {
		t.Fatalf("expected 1 task, got %d", len(out.Tasks))
	}
	// ClickUp personal tokens do NOT use Bearer prefix — verify we don't add one.
	if strings.HasPrefix(sawAuth, "Bearer") {
		t.Errorf("ClickUp Authorization must be raw token, got %q", sawAuth)
	}
	if sawAuth != "pk_1_AAAA" {
		t.Errorf("Authorization header %q, want raw pk_ token", sawAuth)
	}
	if sawPath != "/list/123/task" {
		t.Errorf("path %q", sawPath)
	}
}

func TestClickUpListListsRequiresExactlyOneParent(t *testing.T) {
	gw := newTestGateway()
	req := newCallRequest(map[string]any{})
	res, err := gw.clickupListLists(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	if res == nil || !res.IsError {
		t.Fatalf("expected tool error for missing parent, got %+v", res)
	}

	req = newCallRequest(map[string]any{"folder_id": "f1", "space_id": "s1"})
	res, err = gw.clickupListLists(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	if res == nil || !res.IsError {
		t.Fatalf("expected tool error for conflicting parents, got %+v", res)
	}
}

func TestClickUpHierarchyPaths(t *testing.T) {
	var paths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/team/123/space":
			_, _ = w.Write([]byte(`{"spaces":[]}`))
		case "/space/456/folder":
			_, _ = w.Write([]byte(`{"folders":[]}`))
		case "/folder/789/list", "/space/456/list":
			_, _ = w.Write([]byte(`{"lists":[]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	oldBase := clickupAPIBase
	clickupAPIBase = srv.URL
	defer func() { clickupAPIBase = oldBase }()

	gw := newClickUpTestGateway(srv.Client())
	calls := []func() (*mcpgo.CallToolResult, error){
		func() (*mcpgo.CallToolResult, error) {
			return gw.clickupListSpaces(context.Background(), newCallRequest(map[string]any{"workspace_id": "123"}))
		},
		func() (*mcpgo.CallToolResult, error) {
			return gw.clickupListFolders(context.Background(), newCallRequest(map[string]any{"space_id": "456"}))
		},
		func() (*mcpgo.CallToolResult, error) {
			return gw.clickupListLists(context.Background(), newCallRequest(map[string]any{"folder_id": "789"}))
		},
		func() (*mcpgo.CallToolResult, error) {
			return gw.clickupListLists(context.Background(), newCallRequest(map[string]any{"space_id": "456"}))
		},
	}
	for _, call := range calls {
		res, err := call()
		if err != nil {
			t.Fatal(err)
		}
		if res == nil || res.IsError {
			t.Fatalf("unexpected result: %+v", res)
		}
	}
	want := []string{"/team/123/space", "/space/456/folder", "/folder/789/list", "/space/456/list"}
	if strings.Join(paths, ",") != strings.Join(want, ",") {
		t.Fatalf("paths %v, want %v", paths, want)
	}
}

func TestClickUpCallSurfacesHTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"err":"unauthorized"}`, http.StatusUnauthorized)
	}))
	defer srv.Close()

	gw := newTestGateway()
	gw.HTTP = srv.Client()
	_, err := clickupCallAt(context.Background(), gw, srv.URL+"/team", "pk_bad")
	if err == nil || !strings.Contains(err.Error(), "401") {
		t.Fatalf("expected 401 surface, got %v", err)
	}
}

func clickupCallAt(ctx context.Context, g *Gateway, fullURL, token string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fullURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", token) // raw, no Bearer
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", g.UserAgent)
	resp, err := g.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	buf := make([]byte, 0, 4096)
	chunk := make([]byte, 4096)
	for {
		n, rerr := resp.Body.Read(chunk)
		if n > 0 {
			buf = append(buf, chunk[:n]...)
		}
		if rerr != nil {
			break
		}
	}
	if resp.StatusCode/100 != 2 {
		return buf, &httpStatusErr{code: resp.StatusCode, body: string(buf)}
	}
	return buf, nil
}

type httpStatusErr struct {
	code int
	body string
}

func (e *httpStatusErr) Error() string {
	return "http " + itoa(e.code) + ": " + strings.TrimSpace(e.body)
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var buf [20]byte
	n := len(buf)
	for i > 0 {
		n--
		buf[n] = byte('0' + i%10)
		i /= 10
	}
	return string(buf[n:])
}
