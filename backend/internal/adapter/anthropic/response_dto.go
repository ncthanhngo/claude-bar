package anthropic

// SSE event payload shapes from the Anthropic Messages API.
//
// Anthropic ships a fixed sequence per request:
//   1. message_start          → carries Message{id, usage.input_tokens}
//   2. content_block_start    → declares an outgoing block (text / thinking / tool_use)
//   3. content_block_delta  ⟳ → "text_delta" / "thinking_delta" / "input_json_delta"
//   4. content_block_stop     → closes the current block
//   5. message_delta          → carries final usage.output_tokens + stop_reason
//   6. message_stop           → terminator
//   plus "error" / "ping" events at any time.
//
// We only model the fields we read; everything else is ignored.

type sseEnvelope struct {
	Type    string          `json:"type"`
	Index   int             `json:"index,omitempty"`
	Delta   *sseDelta       `json:"delta,omitempty"`
	Usage   *sseUsage       `json:"usage,omitempty"`
	Message *sseMessageHead `json:"message,omitempty"`
	Error   *sseError       `json:"error,omitempty"`
}

type sseDelta struct {
	Type         string    `json:"type,omitempty"` // "text_delta" | "thinking_delta" | "input_json_delta"
	Text         string    `json:"text,omitempty"`
	Thinking     string    `json:"thinking,omitempty"`
	PartialJSON  string    `json:"partial_json,omitempty"`
	StopReason   string    `json:"stop_reason,omitempty"`
	StopSequence string    `json:"stop_sequence,omitempty"`
	Usage        *sseUsage `json:"usage,omitempty"` // appears nested on message_delta
}

type sseUsage struct {
	InputTokens  int `json:"input_tokens,omitempty"`
	OutputTokens int `json:"output_tokens,omitempty"`

	// Cache fields are emitted on message_start when prompt caching is in
	// effect. Surfaced into StreamUsage.InputTokens (combined) — separating
	// the breakdown is a future analytics concern.
	CacheCreationInputTokens int `json:"cache_creation_input_tokens,omitempty"`
	CacheReadInputTokens     int `json:"cache_read_input_tokens,omitempty"`
}

// effectiveInput returns the cache-inclusive prompt token count for usage
// accounting. Caller pays for all three buckets.
func (u sseUsage) effectiveInput() int {
	return u.InputTokens + u.CacheCreationInputTokens + u.CacheReadInputTokens
}

type sseMessageHead struct {
	ID    string    `json:"id"`
	Usage *sseUsage `json:"usage"`
}

type sseError struct {
	Type    string `json:"type"`
	Message string `json:"message"`
}
