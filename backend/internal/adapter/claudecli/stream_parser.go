package claudecli

import (
	"encoding/json"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// streamLine is the union envelope `claude -p --output-format=stream-json`
// emits. We only decode the fields we care about — text + thinking deltas,
// usage on message_start, stop_reason on message_delta, the final result.
type streamLine struct {
	Type    string           `json:"type"`
	Subtype string           `json:"subtype,omitempty"`
	Event   *streamEvent     `json:"event,omitempty"`   // for type="stream_event"
	Message *streamMessage   `json:"message,omitempty"` // for type="assistant"
	Result  string           `json:"result,omitempty"`  // for type="result"
	IsError bool             `json:"is_error,omitempty"`
	Usage   *streamUsage     `json:"usage,omitempty"`
	StopReason string        `json:"stop_reason,omitempty"`
	ApiErrorStatus *int      `json:"api_error_status,omitempty"`
	DurationMs int           `json:"duration_ms,omitempty"`
}

// streamEvent mirrors a single Anthropic SSE event nested inside Claude
// CLI's stream_event envelope. The shape is the same as the raw Anthropic
// API SSE — content_block_delta, message_start, message_delta, etc.
type streamEvent struct {
	Type    string         `json:"type"`
	Index   int            `json:"index,omitempty"`
	Delta   *streamDelta   `json:"delta,omitempty"`
	Message *streamMessage `json:"message,omitempty"`
	Usage   *streamUsage   `json:"usage,omitempty"`
}

type streamDelta struct {
	Type       string `json:"type"` // "text_delta" | "thinking_delta" | "signature_delta" | "input_json_delta"
	Text       string `json:"text,omitempty"`
	Thinking   string `json:"thinking,omitempty"`
	StopReason string `json:"stop_reason,omitempty"`
}

type streamMessage struct {
	ID    string       `json:"id,omitempty"`
	Model string       `json:"model,omitempty"`
	Usage *streamUsage `json:"usage,omitempty"`
}

type streamUsage struct {
	InputTokens             int `json:"input_tokens,omitempty"`
	OutputTokens            int `json:"output_tokens,omitempty"`
	CacheCreationInputTokens int `json:"cache_creation_input_tokens,omitempty"`
	CacheReadInputTokens    int `json:"cache_read_input_tokens,omitempty"`
}

// effectiveInput returns the cache-inclusive prompt total. Mirrors the
// Anthropic raw-SSE adapter's accounting so the UI shows the same number
// regardless of which transport is in use.
func (u streamUsage) effectiveInput() int {
	return u.InputTokens + u.CacheCreationInputTokens + u.CacheReadInputTokens
}

// decodeLine returns the ChatStreamEvent for one stream-json line, or
// (zero, false) for lines we deliberately skip (init / status / rate_limit
// pings / content_block_start). The final `result` event maps to StreamDone
// (success) or StreamError (failure).
func decodeLine(line string) (domain.ChatStreamEvent, bool) {
	var l streamLine
	if err := json.Unmarshal([]byte(line), &l); err != nil {
		return domain.ChatStreamEvent{}, false
	}

	switch l.Type {
	case "stream_event":
		return decodeStreamEvent(l.Event)
	case "result":
		return decodeResult(l), true
	}
	return domain.ChatStreamEvent{}, false
}

func decodeStreamEvent(ev *streamEvent) (domain.ChatStreamEvent, bool) {
	if ev == nil {
		return domain.ChatStreamEvent{}, false
	}
	switch ev.Type {
	case "message_start":
		if ev.Message != nil && ev.Message.Usage != nil {
			return domain.ChatStreamEvent{
				Kind:        domain.StreamUsage,
				InputTokens: ev.Message.Usage.effectiveInput(),
			}, true
		}
	case "content_block_delta":
		if ev.Delta == nil {
			return domain.ChatStreamEvent{}, false
		}
		switch ev.Delta.Type {
		case "text_delta":
			if ev.Delta.Text == "" {
				return domain.ChatStreamEvent{}, false
			}
			return domain.ChatStreamEvent{
				Kind: domain.StreamTextDelta, Text: ev.Delta.Text,
			}, true
		case "thinking_delta":
			if ev.Delta.Thinking == "" {
				return domain.ChatStreamEvent{}, false
			}
			return domain.ChatStreamEvent{
				Kind: domain.StreamThinkingDelta, Text: ev.Delta.Thinking,
			}, true
		}
	case "message_delta":
		// CLI emits the final stop_reason here; we let the result event
		// carry the canonical Done because it also has total token usage.
		return domain.ChatStreamEvent{}, false
	}
	return domain.ChatStreamEvent{}, false
}

func decodeResult(l streamLine) domain.ChatStreamEvent {
	if l.IsError {
		code := "unknown"
		if l.ApiErrorStatus != nil {
			switch *l.ApiErrorStatus {
			case 429:
				code = "rate_limited"
			case 401, 403:
				code = "auth"
			case 400:
				code = "bad_request"
			default:
				if *l.ApiErrorStatus >= 500 {
					code = "overloaded"
				}
			}
		}
		return domain.ChatStreamEvent{
			Kind:         domain.StreamError,
			ErrorCode:    code,
			ErrorMessage: l.Result,
		}
	}
	usage := l.Usage
	ev := domain.ChatStreamEvent{
		Kind:       domain.StreamDone,
		StopReason: l.StopReason,
	}
	if usage != nil {
		ev.InputTokens = usage.effectiveInput()
		ev.OutputTokens = usage.OutputTokens
	}
	return ev
}
