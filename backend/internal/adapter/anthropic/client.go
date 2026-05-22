package anthropic

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

const (
	messagesEndpoint = "https://api.anthropic.com/v1/messages"
	anthropicVersion = "2023-06-01"
	// oauth-2025-04-20 enables the OAuth Bearer path on /v1/messages.
	// pdfs-2024-09-25 enables document base64 source blocks.
	// prompt-caching-2024-07-31 enables cache_control on system blocks.
	anthropicBetaHeaders = "oauth-2025-04-20,prompt-caching-2024-07-31,pdfs-2024-09-25"
	defaultUserAgent     = "claude-bar-chat/0.1"
)

// ChatClient implements port.ChatClient against the Anthropic Messages API.
type ChatClient struct {
	hc        *http.Client
	userAgent string
}

// NewChatClient returns a streaming-ready ChatClient. The underlying
// http.Client has Timeout=0 because the response body itself is a long-
// lived stream — per-read deadlines / overall cancellation come from ctx.
func NewChatClient() *ChatClient {
	return &ChatClient{
		hc:        &http.Client{Timeout: 0},
		userAgent: defaultUserAgent,
	}
}

// Stream POSTs req to /v1/messages and forwards SSE events on the returned
// channel. The channel closes when the stream terminates (any path: success,
// upstream error, ctx cancel). On a pre-stream auth failure the function
// returns domain.ErrUnauthorized and no channel; the caller refreshes and
// retries. Other pre-stream failures return *httpErrorEvent so the caller
// can forward an equivalent StreamError if it wants.
func (c *ChatClient) Stream(
	ctx context.Context,
	accessToken string,
	req port.ChatRequest,
) (<-chan domain.ChatStreamEvent, error) {
	if accessToken == "" {
		return nil, domain.ErrUnauthorized
	}
	body, err := encodeRequest(req)
	if err != nil {
		return nil, fmt.Errorf("encode request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost,
		messagesEndpoint, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	httpReq.Header.Set("Authorization", "Bearer "+accessToken)
	httpReq.Header.Set("anthropic-version", anthropicVersion)
	httpReq.Header.Set("anthropic-beta", anthropicBetaHeaders)
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "text/event-stream")
	httpReq.Header.Set("User-Agent", c.userAgent)

	resp, err := c.hc.Do(httpReq)
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return nil, domain.ErrStreamCancelled
		}
		log.Printf("[Anthropic] POST %s model=%s err=%v",
			messagesEndpoint, req.Model, err)
		return nil, fmt.Errorf("anthropic post: %w", err)
	}

	log.Printf("[Anthropic] POST %s model=%s status=%d",
		messagesEndpoint, req.Model, resp.StatusCode)

	if resp.StatusCode == http.StatusUnauthorized {
		_ = resp.Body.Close()
		return nil, domain.ErrUnauthorized
	}
	if resp.StatusCode >= 400 {
		return nil, decodeErrorBody(resp)
	}

	out := make(chan domain.ChatStreamEvent, 16)
	go func() {
		defer close(out)
		defer resp.Body.Close()
		parseSSE(ctx, resp.Body, out)
	}()
	return out, nil
}

// Compile-time guard: ChatClient implements the port.
var _ port.ChatClient = (*ChatClient)(nil)
