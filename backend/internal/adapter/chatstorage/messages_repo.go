package chatstorage

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

type messagesRepo struct {
	db *sql.DB
}

func newMessagesRepo(db *sql.DB) *messagesRepo {
	return &messagesRepo{db: db}
}

func (r *messagesRepo) list(ctx context.Context, accountUUID, conversationID string) ([]domain.Message, error) {
	// JOIN forces the account scope at SQL level — a cross-account fetch
	// returns zero rows even if the conversationID happens to collide.
	rows, err := r.db.QueryContext(ctx, `
		SELECT m.id, m.conversation_id, m.role, m.content_json,
		       m.input_tokens, m.output_tokens, m.stop_reason, m.created_at
		  FROM messages m
		  JOIN conversations c ON c.id = m.conversation_id
		 WHERE m.conversation_id = ? AND c.account_uuid = ?
		 ORDER BY m.created_at ASC, m.id ASC
	`, conversationID, accountUUID)
	if err != nil {
		return nil, fmt.Errorf("list messages: %w", err)
	}
	defer rows.Close()

	var out []domain.Message
	for rows.Next() {
		m, err := scanMessage(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func (r *messagesRepo) append(ctx context.Context, accountUUID string, m *domain.Message) error {
	if err := r.guardAccount(ctx, accountUUID, m.ConversationID); err != nil {
		return err
	}
	content, err := json.Marshal(m.Content)
	if err != nil {
		return fmt.Errorf("marshal content: %w", err)
	}

	// Wrap message insert + conversation updated_at bump in one txn so a
	// ctx cancellation between them can't leave the rail mis-ordered.
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin append txn: %w", err)
	}
	defer func() { _ = tx.Rollback() }() // no-op after Commit

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO messages (id, conversation_id, role, content_json, plain_text,
		                      input_tokens, output_tokens, stop_reason, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
	`,
		m.ID, m.ConversationID, string(m.Role), string(content), m.PlainText(),
		m.InputTokens, m.OutputTokens, m.StopReason,
		m.CreatedAt.UnixMilli(),
	); err != nil {
		return fmt.Errorf("append message: %w", err)
	}

	if _, err := tx.ExecContext(ctx,
		`UPDATE conversations SET updated_at = ? WHERE id = ?`,
		m.CreatedAt.UnixMilli(), m.ConversationID,
	); err != nil {
		return fmt.Errorf("bump conversation updated_at: %w", err)
	}
	return tx.Commit()
}

func (r *messagesRepo) update(ctx context.Context, accountUUID string, m *domain.Message) error {
	if err := r.guardAccount(ctx, accountUUID, m.ConversationID); err != nil {
		return err
	}
	content, err := json.Marshal(m.Content)
	if err != nil {
		return fmt.Errorf("marshal content: %w", err)
	}
	_, err = r.db.ExecContext(ctx, `
		UPDATE messages
		   SET content_json = ?, plain_text = ?,
		       input_tokens = ?, output_tokens = ?, stop_reason = ?
		 WHERE id = ? AND conversation_id = ?
	`,
		string(content), m.PlainText(),
		m.InputTokens, m.OutputTokens, m.StopReason,
		m.ID, m.ConversationID,
	)
	if err != nil {
		return fmt.Errorf("update message: %w", err)
	}
	return nil
}

// search runs a substring match on the FTS5 plain_text projection across
// the entire account. Results return newest first, capped by limit.
func (r *messagesRepo) search(ctx context.Context, accountUUID, query string, limit int) ([]domain.Message, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT m.id, m.conversation_id, m.role, m.content_json,
		       m.input_tokens, m.output_tokens, m.stop_reason, m.created_at
		  FROM messages_fts f
		  JOIN messages m ON m.rowid = f.rowid
		  JOIN conversations c ON c.id = m.conversation_id
		 WHERE c.account_uuid = ?
		   AND messages_fts MATCH ?
		 ORDER BY m.created_at DESC
		 LIMIT ?
	`, accountUUID, query, limit)
	if err != nil {
		return nil, fmt.Errorf("search messages: %w", err)
	}
	defer rows.Close()

	var out []domain.Message
	for rows.Next() {
		m, err := scanMessage(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// guardAccount checks that conversationID belongs to accountUUID, returning
// ErrConversationNotFound / ErrAccountMismatch as appropriate.
func (r *messagesRepo) guardAccount(ctx context.Context, accountUUID, conversationID string) error {
	var owner string
	err := r.db.QueryRowContext(ctx,
		`SELECT account_uuid FROM conversations WHERE id = ?`, conversationID,
	).Scan(&owner)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.ErrConversationNotFound
	}
	if err != nil {
		return fmt.Errorf("guard account: %w", err)
	}
	if owner != accountUUID {
		return domain.ErrAccountMismatch
	}
	return nil
}

func scanMessage(s scanner) (domain.Message, error) {
	var (
		m         domain.Message
		role      string
		content   string
		createdMs int64
	)
	if err := s.Scan(
		&m.ID, &m.ConversationID, &role, &content,
		&m.InputTokens, &m.OutputTokens, &m.StopReason,
		&createdMs,
	); err != nil {
		return m, err
	}
	m.Role = domain.Role(role)
	if content != "" {
		if err := json.Unmarshal([]byte(content), &m.Content); err != nil {
			return m, fmt.Errorf("decode content_json for %s: %w", m.ID, err)
		}
	}
	m.CreatedAt = time.UnixMilli(createdMs).UTC()
	return m, nil
}
