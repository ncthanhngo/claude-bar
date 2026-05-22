package domain

import "time"

// Role identifies the speaker of a message turn. Anthropic API distinguishes
// user / assistant turns; system content is hoisted out into Conversation.SystemPrompt
// at request time, but we still tag system-origin entries when stored locally
// (e.g. a future "assistant reset" annotation).
type Role string

const (
	RoleUser      Role = "user"
	RoleAssistant Role = "assistant"
	RoleSystem    Role = "system"
)

// Message is one turn in a Conversation. Content is a list of ContentBlocks so
// multimodal (text + image + document) messages remain one logical turn rather
// than several rows. Token counts and StopReason come from the Anthropic
// streaming usage event and are zero for in-flight messages.
type Message struct {
	ID             string
	ConversationID string
	Role           Role
	Content        []ContentBlock

	// Token accounting reported by Anthropic; zero before stream completes.
	InputTokens  int
	OutputTokens int

	// "end_turn" | "max_tokens" | "stop_sequence" | "tool_use" | "" (in-flight).
	StopReason string

	CreatedAt time.Time
}

// PlainText concatenates every text block in order. Convenience for UI
// previews / search indexing — not a substitute for rendering full Content.
func (m Message) PlainText() string {
	out := ""
	for _, b := range m.Content {
		if b.Kind == BlockText {
			out += b.Text
		}
	}
	return out
}
