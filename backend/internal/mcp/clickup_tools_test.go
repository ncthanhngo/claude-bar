package mcp

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

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
