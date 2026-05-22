package port

import (
	"context"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// ChatStorage is the per-account persistence port for chat data. Every method
// takes accountUUID first and the implementation MUST scope to that account —
// even getting a conversation by ID returns ErrAccountMismatch if the row
// belongs to someone else. The MVP backing store is one SQLCipher DB file
// per account (phase 04); a fake in-memory impl backs unit tests.
type ChatStorage interface {
	// --- Conversations ---

	ListConversations(ctx context.Context, accountUUID string) ([]domain.Conversation, error)
	GetConversation(ctx context.Context, accountUUID, id string) (*domain.Conversation, error)
	CreateConversation(ctx context.Context, c *domain.Conversation) error
	UpdateConversation(ctx context.Context, c *domain.Conversation) error
	DeleteConversation(ctx context.Context, accountUUID, id string) error

	// --- Messages ---

	ListMessages(ctx context.Context, accountUUID, conversationID string) ([]domain.Message, error)
	AppendMessage(ctx context.Context, accountUUID string, m *domain.Message) error
	UpdateMessage(ctx context.Context, accountUUID string, m *domain.Message) error

	// --- Attachments ---

	CreateAttachment(ctx context.Context, accountUUID string, a *domain.Attachment) error
	GetAttachment(ctx context.Context, accountUUID, id string) (*domain.Attachment, error)
	DeleteAttachment(ctx context.Context, accountUUID, id string) error

	// --- Search ---

	// SearchMessages returns messages whose plain-text content matches the
	// query (FTS5 in the SQLCipher impl). Results are ordered by recency,
	// capped by limit. Implementations that don't support FTS may fall back
	// to LIKE % %.
	SearchMessages(ctx context.Context, accountUUID, query string, limit int) ([]domain.Message, error)

	// --- Lifecycle ---

	Close() error
}
