package domain

// StreamEventKind discriminates the events emitted while a chat request is
// streaming. text_delta carries partial assistant text; usage / done carry
// token accounting; error carries a categorised failure so the UI can react
// (rate_limited surfaces a wait time, auth triggers a re-login flow).
type StreamEventKind string

const (
	StreamTextDelta     StreamEventKind = "text_delta"
	StreamThinkingDelta StreamEventKind = "thinking_delta"
	StreamUsage         StreamEventKind = "usage"
	StreamDone          StreamEventKind = "done"
	StreamError         StreamEventKind = "error"
)

// ChatStreamEvent is one event on the channel returned by ChatClient.Stream.
// Only the fields documented per Kind are populated; readers must branch on
// Kind first and only read the relevant subset.
type ChatStreamEvent struct {
	Kind StreamEventKind

	// StreamTextDelta: token-level chunk to append to the assistant message.
	// StreamThinkingDelta: chunk of the assistant's extended-thinking trace —
	// rendered in its own collapsible UI block, not the main reply body.
	Text string

	// StreamUsage / StreamDone: running and final token counts.
	InputTokens  int
	OutputTokens int

	// StreamDone: Anthropic stop reason ("end_turn" | "max_tokens" | "stop_sequence" | "tool_use").
	StopReason string

	// StreamError: machine-readable category for UI routing.
	// Allowed: "rate_limited" | "auth" | "overloaded" | "network" | "bad_request" | "unknown".
	ErrorCode string

	// StreamError: human-readable message (already redacted of any token / PII).
	ErrorMessage string

	// StreamError (rate_limited): seconds to wait before retrying; 0 if unknown.
	RetryAfterS int
}
