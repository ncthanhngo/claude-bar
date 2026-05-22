package chat

import (
	"context"
	"errors"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// CreateConversation mints a new Conversation in the active account's
// storage. `title` may be empty — the UI usually auto-derives one from the
// first user message after the conversation has run.
func (s *Service) CreateConversation(ctx context.Context, accountNum int, model, systemPrompt, title string) (*domain.Conversation, error) {
	_, accountUUID, storage, err := s.openForAccount(ctx, accountNum)
	if err != nil {
		return nil, err
	}
	defer storage.Close()

	now := s.Now()
	c := &domain.Conversation{
		ID:           s.NewID(),
		AccountUUID:  accountUUID,
		Title:        strings.TrimSpace(title),
		Model:        model,
		SystemPrompt: systemPrompt,
		CreatedAt:    now,
		UpdatedAt:    now,
	}
	if err := storage.CreateConversation(ctx, c); err != nil {
		return nil, err
	}
	return c, nil
}

// ListConversations returns all conversations for the active account,
// sorted by most-recently-updated first (storage handles the ordering).
func (s *Service) ListConversations(ctx context.Context, accountNum int) ([]domain.Conversation, error) {
	_, accountUUID, storage, err := s.openForAccount(ctx, accountNum)
	if err != nil {
		return nil, err
	}
	defer storage.Close()
	return storage.ListConversations(ctx, accountUUID)
}

// LoadConversation returns the conversation metadata + all messages.
// Returns domain.ErrConversationNotFound when the id doesn't exist.
func (s *Service) LoadConversation(ctx context.Context, accountNum int, conversationID string) (*domain.Conversation, []domain.Message, error) {
	_, accountUUID, storage, err := s.openForAccount(ctx, accountNum)
	if err != nil {
		return nil, nil, err
	}
	defer storage.Close()

	conv, err := storage.GetConversation(ctx, accountUUID, conversationID)
	if err != nil {
		return nil, nil, err
	}
	msgs, err := storage.ListMessages(ctx, accountUUID, conversationID)
	if err != nil {
		return nil, nil, err
	}
	return conv, msgs, nil
}

// RenameConversation updates the title in place + bumps updated_at. Empty
// strings are accepted (lets the UI clear an auto-title).
func (s *Service) RenameConversation(ctx context.Context, accountNum int, conversationID, newTitle string) error {
	_, accountUUID, storage, err := s.openForAccount(ctx, accountNum)
	if err != nil {
		return err
	}
	defer storage.Close()

	conv, err := storage.GetConversation(ctx, accountUUID, conversationID)
	if err != nil {
		return err
	}
	conv.Title = strings.TrimSpace(newTitle)
	conv.UpdatedAt = s.Now()
	return storage.UpdateConversation(ctx, conv)
}

// SetConversationModel switches the model id used for subsequent
// SendMessage calls on this conversation. Empty model strings are rejected
// — the send-message path requires a non-empty id to look up routing in the
// models catalog. Returns ErrConversationNotFound when the id doesn't exist.
func (s *Service) SetConversationModel(ctx context.Context, accountNum int, conversationID, model string) error {
	model = strings.TrimSpace(model)
	if model == "" {
		return errors.New("chat: model id is required")
	}
	_, accountUUID, storage, err := s.openForAccount(ctx, accountNum)
	if err != nil {
		return err
	}
	defer storage.Close()

	conv, err := storage.GetConversation(ctx, accountUUID, conversationID)
	if err != nil {
		return err
	}
	conv.Model = model
	conv.UpdatedAt = s.Now()
	return storage.UpdateConversation(ctx, conv)
}

// DeleteConversation removes the conversation row. The schema's ON DELETE
// CASCADE on messages + attachments rows handles the DB cleanup; the
// on-disk encrypted attachment files are NOT removed here (purposely — a
// future "trash + restore" feature can recover them). Phase 09 may add a
// vault sweep for orphans.
func (s *Service) DeleteConversation(ctx context.Context, accountNum int, conversationID string) error {
	_, accountUUID, storage, err := s.openForAccount(ctx, accountNum)
	if err != nil {
		return err
	}
	defer storage.Close()
	return storage.DeleteConversation(ctx, accountUUID, conversationID)
}
