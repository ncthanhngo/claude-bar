package chatstorage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

type attachmentsRepo struct {
	db *sql.DB
}

func newAttachmentsRepo(db *sql.DB) *attachmentsRepo {
	return &attachmentsRepo{db: db}
}

func (r *attachmentsRepo) create(ctx context.Context, accountUUID string, a *domain.Attachment) error {
	if err := guardConversationOwnership(ctx, r.db, accountUUID, a.ConversationID); err != nil {
		return err
	}
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO attachments (id, conversation_id, message_id, kind, filename, media_type,
		                          size_bytes, file_path, nonce_hex, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`,
		a.ID, a.ConversationID, a.MessageID, string(a.Kind),
		a.Filename, a.MediaType, a.SizeBytes,
		a.FilePath, a.NonceHex,
		a.CreatedAt.UnixMilli(),
	)
	if err != nil {
		return fmt.Errorf("create attachment: %w", err)
	}
	return nil
}

func (r *attachmentsRepo) get(ctx context.Context, accountUUID, id string) (*domain.Attachment, error) {
	var (
		a         domain.Attachment
		kind      string
		createdMs int64
	)
	err := r.db.QueryRowContext(ctx, `
		SELECT a.id, a.conversation_id, a.message_id, a.kind, a.filename, a.media_type,
		       a.size_bytes, a.file_path, a.nonce_hex, a.created_at
		  FROM attachments a
		  JOIN conversations c ON c.id = a.conversation_id
		 WHERE a.id = ? AND c.account_uuid = ?
	`, id, accountUUID).Scan(
		&a.ID, &a.ConversationID, &a.MessageID, &kind, &a.Filename, &a.MediaType,
		&a.SizeBytes, &a.FilePath, &a.NonceHex, &createdMs,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, domain.ErrConversationNotFound // close enough — attachment-not-found
	}
	if err != nil {
		return nil, fmt.Errorf("get attachment: %w", err)
	}
	a.Kind = domain.AttachmentKind(kind)
	a.CreatedAt = time.UnixMilli(createdMs).UTC()
	return &a, nil
}

func (r *attachmentsRepo) delete(ctx context.Context, accountUUID, id string) error {
	// Two-step: confirm ownership, then delete. Single statement with JOIN
	// isn't supported in sqlite's DELETE form.
	if _, err := r.get(ctx, accountUUID, id); err != nil {
		return err
	}
	_, err := r.db.ExecContext(ctx, `DELETE FROM attachments WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("delete attachment: %w", err)
	}
	return nil
}

// guardConversationOwnership is exported across repos to assert that a child
// row's conversation_id resolves to the expected account_uuid.
func guardConversationOwnership(ctx context.Context, db *sql.DB, accountUUID, conversationID string) error {
	var owner string
	err := db.QueryRowContext(ctx,
		`SELECT account_uuid FROM conversations WHERE id = ?`, conversationID,
	).Scan(&owner)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.ErrConversationNotFound
	}
	if err != nil {
		return fmt.Errorf("guard ownership: %w", err)
	}
	if owner != accountUUID {
		return domain.ErrAccountMismatch
	}
	return nil
}
