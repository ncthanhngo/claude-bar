package anthropic

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// parseSSE reads Anthropic Server-Sent Events from body, decodes each
// `data: …` line, and forwards translated ChatStreamEvents on out. The
// caller is responsible for closing body — we stop reading on the first
// of: scanner EOF, ctx cancellation, or any send-side ctx cancel detected
// while pushing to out. The channel is closed by the caller goroutine.
//
// SSE buffer is sized 4MB to survive a single large content block.
func parseSSE(ctx context.Context, body io.Reader, out chan<- domain.ChatStreamEvent) {
	sc := bufio.NewScanner(body)
	sc.Buffer(make([]byte, 0, 64<<10), 4<<20)

	for sc.Scan() {
		line := sc.Text()
		// SSE: skip blank lines, comments, and `event:` headers — we
		// branch off `type` inside the data payload instead.
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		payload := strings.TrimPrefix(line, "data: ")
		if payload == "" || payload == "[DONE]" {
			continue
		}
		ev, ok := decodeEvent(payload)
		if !ok {
			continue
		}
		select {
		case out <- ev:
		case <-ctx.Done():
			return
		}
	}
	if err := sc.Err(); err != nil &&
		!errors.Is(err, context.Canceled) &&
		!errors.Is(err, io.EOF) {
		if errors.Is(err, bufio.ErrTooLong) {
			log.Printf("[Anthropic] SSE line exceeded 4MB buffer; stream aborted")
		}
		select {
		case out <- domain.ChatStreamEvent{
			Kind:         domain.StreamError,
			ErrorCode:    "network",
			ErrorMessage: err.Error(),
		}:
		case <-ctx.Done():
		}
	}
}

// decodeEvent maps one SSE JSON payload to a ChatStreamEvent. Returns
// (zero, false) for events we deliberately ignore (ping, content_block_start,
// content_block_stop, message_stop) — those don't carry user-visible state.
func decodeEvent(payload string) (domain.ChatStreamEvent, bool) {
	var env sseEnvelope
	if err := json.Unmarshal([]byte(payload), &env); err != nil {
		return domain.ChatStreamEvent{}, false
	}
	switch env.Type {
	case "message_start":
		if env.Message != nil && env.Message.Usage != nil {
			u := env.Message.Usage
			return domain.ChatStreamEvent{
				Kind:        domain.StreamUsage,
				InputTokens: u.effectiveInput(),
			}, true
		}
	case "content_block_delta":
		if env.Delta == nil {
			return domain.ChatStreamEvent{}, false
		}
		switch env.Delta.Type {
		case "text_delta":
			if env.Delta.Text == "" {
				return domain.ChatStreamEvent{}, false
			}
			return domain.ChatStreamEvent{
				Kind: domain.StreamTextDelta, Text: env.Delta.Text,
			}, true
		case "thinking_delta":
			if env.Delta.Thinking == "" {
				return domain.ChatStreamEvent{}, false
			}
			return domain.ChatStreamEvent{
				Kind: domain.StreamThinkingDelta, Text: env.Delta.Thinking,
			}, true
		}
	case "message_delta":
		if env.Delta == nil {
			return domain.ChatStreamEvent{}, false
		}
		ev := domain.ChatStreamEvent{
			Kind:       domain.StreamDone,
			StopReason: env.Delta.StopReason,
		}
		if u := env.Delta.Usage; u != nil {
			ev.InputTokens = u.effectiveInput()
			ev.OutputTokens = u.OutputTokens
		}
		return ev, true
	case "error":
		if env.Error == nil {
			return domain.ChatStreamEvent{}, false
		}
		return domain.ChatStreamEvent{
			Kind:         domain.StreamError,
			ErrorCode:    classifyErrorType(env.Error.Type),
			ErrorMessage: env.Error.Message,
		}, true
	case "ping", "content_block_start", "content_block_stop", "message_stop":
		// Known-but-ignored event types; documented in response_dto.go.
	default:
		log.Printf("[Anthropic] unknown SSE event type=%s — adapter may be lagging API", env.Type)
	}
	return domain.ChatStreamEvent{}, false
}

// classifyErrorType maps Anthropic error.type strings to our normalised codes.
// "overloaded_error" / "rate_limit_error" become the same broad category
// the UI knows how to react to.
func classifyErrorType(t string) string {
	switch t {
	case "overloaded_error":
		return "overloaded"
	case "rate_limit_error":
		return "rate_limited"
	case "authentication_error", "permission_error":
		return "auth"
	case "invalid_request_error":
		return "bad_request"
	default:
		return "unknown"
	}
}
