package port

import (
	"context"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// ChatRequest is the canonical input for one chat turn. Anthropic-specific
// shape lives in the adapter (request DTO) — this struct stays stable across
// providers so a hypothetical second backend could swap in.
type ChatRequest struct {
	Model        string
	SystemPrompt string

	// Messages: full history loaded with content blocks. The adapter maps
	// each block to the provider's wire format (image_base64, document_base64
	// for Anthropic). Order matters; turn N+1 must follow turn N.
	Messages []domain.Message

	// MaxTokens caps the assistant response. Defaults to 4096 when zero.
	MaxTokens int

	// Stream is always true for the Daily chat use case — we only have a
	// streaming UI surface. Kept as a field so a future "background summary"
	// call can run non-streaming if needed.
	Stream bool
}

// ChatClient is the Anthropic-facing port. Implementations: oauth-bound
// Messages API in MVP (phase 03); api-key fallback later (phase 09).
type ChatClient interface {
	// Stream sends the request and returns a channel of streaming events.
	// The channel closes after either StreamDone or StreamError. Cancel via
	// ctx — the adapter must propagate ctx into its underlying HTTP call.
	// `accessToken` is a fresh OAuth bearer token; the adapter does not
	// refresh it (that belongs to OAuthTokenProvider).
	Stream(ctx context.Context, accessToken string, req ChatRequest) (<-chan domain.ChatStreamEvent, error)
}
