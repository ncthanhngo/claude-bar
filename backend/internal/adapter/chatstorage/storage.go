package chatstorage

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"os"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// Storage is a per-account SQLCipher-backed ChatStorage implementation.
// Lifecycle: one instance per active account. Owner (composition root in
// cmd/csw) is responsible for closing the old instance + opening the new
// one when the active account switches.
type Storage struct {
	db            *sql.DB
	accountUUID   string
	dbPath        string
	attachmentDir string

	vault            *AttachmentVault
	conversations    *conversationsRepo
	messages         *messagesRepo
	attachmentsRepo  *attachmentsRepo
}

// Open creates / opens the SQLCipher DB and the attachment vault for
// accountUUID. dbPath / attachmentDir default to the standard widget data
// paths when empty — tests inject temp dirs by passing both.
func Open(
	ctx context.Context,
	accountUUID string,
	keyStore port.ChatDBKeyStore,
	dbPath, attachmentDir string,
) (*Storage, error) {
	if accountUUID == "" {
		return nil, fmt.Errorf("chatstorage.Open: empty accountUUID")
	}
	if dbPath == "" {
		dbPath = adapter.ChatDBFile(accountUUID)
	}
	if attachmentDir == "" {
		attachmentDir = adapter.ChatAttachmentDir(accountUUID)
	}

	db, attachKey, err := openEncryptedDB(ctx, accountUUID, keyStore, dbPath)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(attachmentDir, 0o700); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ensure attachment dir: %w", err)
	}
	vault, err := NewAttachmentVault(attachKey, accountUUID, attachmentDir)
	if err != nil {
		_ = db.Close()
		return nil, err
	}
	return &Storage{
		db:               db,
		accountUUID:      accountUUID,
		dbPath:           dbPath,
		attachmentDir:    attachmentDir,
		vault:            vault,
		conversations:    newConversationsRepo(db),
		messages:         newMessagesRepo(db),
		attachmentsRepo:  newAttachmentsRepo(db),
	}, nil
}

// AccountUUID returns the account this storage is bound to.
func (s *Storage) AccountUUID() string { return s.accountUUID }

// Vault exposes the AEAD vault for the chat usecase, which orchestrates
// attachment write (vault.Write → row insert) and read (row fetch →
// vault.Read).
func (s *Storage) Vault() *AttachmentVault { return s.vault }

// --- port.ChatStorage impl ---

func (s *Storage) ListConversations(ctx context.Context, accountUUID string) ([]domain.Conversation, error) {
	if err := s.scope(accountUUID); err != nil {
		return nil, err
	}
	return s.conversations.list(ctx, accountUUID)
}

func (s *Storage) GetConversation(ctx context.Context, accountUUID, id string) (*domain.Conversation, error) {
	if err := s.scope(accountUUID); err != nil {
		return nil, err
	}
	return s.conversations.get(ctx, accountUUID, id)
}

func (s *Storage) CreateConversation(ctx context.Context, c *domain.Conversation) error {
	if err := s.scope(c.AccountUUID); err != nil {
		return err
	}
	return s.conversations.create(ctx, c)
}

func (s *Storage) UpdateConversation(ctx context.Context, c *domain.Conversation) error {
	if err := s.scope(c.AccountUUID); err != nil {
		return err
	}
	return s.conversations.update(ctx, c)
}

func (s *Storage) DeleteConversation(ctx context.Context, accountUUID, id string) error {
	if err := s.scope(accountUUID); err != nil {
		return err
	}
	return s.conversations.delete(ctx, accountUUID, id)
}

func (s *Storage) ListMessages(ctx context.Context, accountUUID, conversationID string) ([]domain.Message, error) {
	if err := s.scope(accountUUID); err != nil {
		return nil, err
	}
	return s.messages.list(ctx, accountUUID, conversationID)
}

func (s *Storage) AppendMessage(ctx context.Context, accountUUID string, m *domain.Message) error {
	if err := s.scope(accountUUID); err != nil {
		return err
	}
	return s.messages.append(ctx, accountUUID, m)
}

func (s *Storage) UpdateMessage(ctx context.Context, accountUUID string, m *domain.Message) error {
	if err := s.scope(accountUUID); err != nil {
		return err
	}
	return s.messages.update(ctx, accountUUID, m)
}

func (s *Storage) CreateAttachment(ctx context.Context, accountUUID string, a *domain.Attachment) error {
	if err := s.scope(accountUUID); err != nil {
		return err
	}
	return s.attachmentsRepo.create(ctx, accountUUID, a)
}

func (s *Storage) GetAttachment(ctx context.Context, accountUUID, id string) (*domain.Attachment, error) {
	if err := s.scope(accountUUID); err != nil {
		return nil, err
	}
	return s.attachmentsRepo.get(ctx, accountUUID, id)
}

func (s *Storage) DeleteAttachment(ctx context.Context, accountUUID, id string) error {
	if err := s.scope(accountUUID); err != nil {
		return err
	}
	return s.attachmentsRepo.delete(ctx, accountUUID, id)
}

func (s *Storage) SearchMessages(ctx context.Context, accountUUID, query string, limit int) ([]domain.Message, error) {
	if err := s.scope(accountUUID); err != nil {
		return nil, err
	}
	return s.messages.search(ctx, accountUUID, query, limit)
}

func (s *Storage) Close() error {
	if s.db == nil {
		return nil
	}
	// Flush WAL → main file so the on-disk DB is self-contained.
	if _, err := s.db.ExecContext(context.Background(), `PRAGMA wal_checkpoint(TRUNCATE)`); err != nil {
		log.Printf("[chatstorage] WAL checkpoint failed for account=%s: %v", s.accountUUID, err)
	}
	err := s.db.Close()
	s.db = nil
	return err
}

// scope rejects any cross-account call. Defensive — repo layer also guards
// by account_uuid in WHERE clauses, but catching it here yields a fast,
// consistent ErrAccountMismatch without a round-trip to the DB.
func (s *Storage) scope(accountUUID string) error {
	if accountUUID != s.accountUUID {
		return domain.ErrAccountMismatch
	}
	return nil
}

// Compile-time guard.
var _ port.ChatStorage = (*Storage)(nil)
