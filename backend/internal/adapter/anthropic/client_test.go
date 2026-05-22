package anthropic

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

func newTestClient(t *testing.T, srv *httptest.Server) *ChatClient {
	t.Helper()
	c := NewChatClient()
	// Redirect the endpoint by swapping the http.Client transport — tests
	// stay close to production code without exposing endpoint config.
	c.hc = srv.Client()
	c.hc.Transport = &rewriteTransport{base: srv.Client().Transport, target: srv.URL}
	return c
}

type rewriteTransport struct {
	base   http.RoundTripper
	target string
}

func (r *rewriteTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	u := *req.URL
	u.Scheme = "http"
	u.Host = strings.TrimPrefix(r.target, "http://")
	u.Host = strings.TrimPrefix(u.Host, "https://")
	req2 := req.Clone(req.Context())
	req2.URL = &u
	req2.Host = u.Host
	if r.base == nil {
		return http.DefaultTransport.RoundTrip(req2)
	}
	return r.base.RoundTrip(req2)
}

func minimalReq() port.ChatRequest {
	return port.ChatRequest{
		Model:    "claude-sonnet-4-6",
		Messages: []domain.Message{{ID: "m1", Role: domain.RoleUser, Content: []domain.ContentBlock{{Kind: domain.BlockText, Text: "hi"}}}},
		Stream:   true,
	}
}

func TestStream_HappyPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer tok-fresh" {
			t.Errorf("Authorization header = %q", got)
		}
		if got := r.Header.Get("anthropic-version"); got != anthropicVersion {
			t.Errorf("anthropic-version = %q", got)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(fixtureSSE))
	}))
	defer srv.Close()

	c := newTestClient(t, srv)
	ch, err := c.Stream(context.Background(), "tok-fresh", minimalReq())
	if err != nil {
		t.Fatalf("Stream err = %v", err)
	}
	count := 0
	for range ch {
		count++
	}
	if count != 6 {
		t.Fatalf("events = %d, want 6", count)
	}
}

func TestStream_Unauthorized(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"type":"authentication_error","message":"invalid"}}`))
	}))
	defer srv.Close()

	c := newTestClient(t, srv)
	_, err := c.Stream(context.Background(), "tok-stale", minimalReq())
	if !errors.Is(err, domain.ErrUnauthorized) {
		t.Fatalf("err = %v, want ErrUnauthorized", err)
	}
}

func TestStream_RateLimited(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Retry-After", "30")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"error":{"type":"rate_limit_error","message":"slow down"}}`))
	}))
	defer srv.Close()

	c := newTestClient(t, srv)
	_, err := c.Stream(context.Background(), "tok", minimalReq())
	var httpErr *httpErrorEvent
	if !errors.As(err, &httpErr) {
		t.Fatalf("err = %v, want *httpErrorEvent", err)
	}
	if httpErr.Code != "rate_limited" {
		t.Errorf("code = %q, want rate_limited", httpErr.Code)
	}
	if httpErr.RetryAfterS != 30 {
		t.Errorf("retry-after = %d, want 30", httpErr.RetryAfterS)
	}
}

func TestStream_NoToken(t *testing.T) {
	c := NewChatClient()
	_, err := c.Stream(context.Background(), "", minimalReq())
	if !errors.Is(err, domain.ErrUnauthorized) {
		t.Fatalf("err = %v, want ErrUnauthorized", err)
	}
}

func TestStream_ContextCancel(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fl, _ := w.(http.Flusher)
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		// Stream forever until client disconnects.
		for i := 0; i < 10000; i++ {
			_, err := w.Write([]byte(`data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}` + "\n\n"))
			if err != nil {
				return
			}
			if fl != nil {
				fl.Flush()
			}
			time.Sleep(2 * time.Millisecond)
		}
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	c := newTestClient(t, srv)
	ch, err := c.Stream(ctx, "tok", minimalReq())
	if err != nil {
		t.Fatalf("Stream err = %v", err)
	}
	// Drain a few then cancel.
	for i := 0; i < 3; i++ {
		<-ch
	}
	cancel()

	done := make(chan struct{})
	go func() {
		for range ch {
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("channel did not close within 500ms after ctx cancel")
	}
}
