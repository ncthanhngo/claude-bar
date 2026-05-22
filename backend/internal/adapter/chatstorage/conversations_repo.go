package chatstorage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

type conversationsRepo struct {
	db *sql.DB
}

func newConversationsRepo(db *sql.DB) *conversationsRepo {
	return &conversationsRepo{db: db}
}

func (r *conversationsRepo) list(ctx context.Context, accountUUID string) ([]domain.Conversation, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, account_uuid, title, model, system_prompt, archived, created_at, updated_at
		FROM conversations
		WHERE account_uuid = ?
		ORDER BY updated_at DESC
	`, accountUUID)
	if err != nil {
		return nil, fmt.Errorf("list conversations: %w", err)
	}
	defer rows.Close()

	var out []domain.Conversation
	for rows.Next() {
		c, err := scanConversation(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (r *conversationsRepo) get(ctx context.Context, accountUUID, id string) (*domain.Conversation, error) {
	row := r.db.QueryRowContext(ctx, `
		SELECT id, account_uuid, title, model, system_prompt, archived, created_at, updated_at
		FROM conversations
		WHERE id = ?
	`, id)
	c, err := scanConversation(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, domain.ErrConversationNotFound
	}
	if err != nil {
		return nil, err
	}
	if !c.IsForAccount(accountUUID) {
		return nil, domain.ErrAccountMismatch
	}
	return &c, nil
}

func (r *conversationsRepo) create(ctx context.Context, c *domain.Conversation) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO conversations (id, account_uuid, title, model, system_prompt, archived, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	`,
		c.ID, c.AccountUUID, c.Title, c.Model, c.SystemPrompt,
		boolToInt(c.Archived),
		c.CreatedAt.UnixMilli(), c.UpdatedAt.UnixMilli(),
	)
	if err != nil {
		return fmt.Errorf("create conversation: %w", err)
	}
	return nil
}

func (r *conversationsRepo) update(ctx context.Context, c *domain.Conversation) error {
	res, err := r.db.ExecContext(ctx, `
		UPDATE conversations
		   SET title = ?, model = ?, system_prompt = ?, archived = ?, updated_at = ?
		 WHERE id = ? AND account_uuid = ?
	`,
		c.Title, c.Model, c.SystemPrompt, boolToInt(c.Archived),
		c.UpdatedAt.UnixMilli(),
		c.ID, c.AccountUUID,
	)
	if err != nil {
		return fmt.Errorf("update conversation: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		// Either it doesn't exist or it belongs to a different account.
		// Probe to give the right sentinel — get() returns
		// ErrConversationNotFound or ErrAccountMismatch accordingly.
		if _, err := r.get(ctx, c.AccountUUID, c.ID); err != nil {
			return err
		}
		// Row exists and matches account but UPDATE matched zero rows.
		// SQLite's MAX_CHANGES is 0 only when row is identical — treat
		// as success to keep idempotent "save with no changes" working.
	}
	return nil
}

func (r *conversationsRepo) delete(ctx context.Context, accountUUID, id string) error {
	res, err := r.db.ExecContext(ctx,
		`DELETE FROM conversations WHERE id = ? AND account_uuid = ?`, id, accountUUID,
	)
	if err != nil {
		return fmt.Errorf("delete conversation: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return domain.ErrConversationNotFound
	}
	return nil
}

// scanner is the minimal contract satisfied by both *sql.Row and *sql.Rows
// so scanConversation works for both single-row and many-row reads.
type scanner interface {
	Scan(dest ...any) error
}

func scanConversation(s scanner) (domain.Conversation, error) {
	var (
		c            domain.Conversation
		archived     int
		createdMs    int64
		updatedMs    int64
	)
	if err := s.Scan(
		&c.ID, &c.AccountUUID, &c.Title, &c.Model, &c.SystemPrompt,
		&archived, &createdMs, &updatedMs,
	); err != nil {
		return c, err
	}
	c.Archived = archived != 0
	c.CreatedAt = time.UnixMilli(createdMs).UTC()
	c.UpdatedAt = time.UnixMilli(updatedMs).UTC()
	return c, nil
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
