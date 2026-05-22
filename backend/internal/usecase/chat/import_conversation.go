package chat

import (
	"context"
	"encoding/base64"
	"fmt"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// ImportConversation recreates a conversation + messages + attachments in
// the active account's storage from an ExportBundle. Conversation gets a
// fresh ID (so re-importing the same bundle creates a new copy rather
// than colliding) — likewise for messages and attachments. The mapping
// from old → new IDs is applied to message content blocks so attachment
// references stay valid after the rewrite.
//
// Schema mismatch returns an error rather than guessing.
func (s *Service) ImportConversation(
	ctx context.Context,
	accountNum int,
	bundle *ExportBundle,
) (*domain.Conversation, error) {
	if bundle == nil {
		return nil, fmt.Errorf("chat.Import: nil bundle")
	}
	if bundle.Schema != ExportBundleSchema {
		return nil, fmt.Errorf("chat.Import: schema mismatch (got %d, want %d)",
			bundle.Schema, ExportBundleSchema)
	}
	_, accountUUID, storage, err := s.openForAccount(ctx, accountNum)
	if err != nil {
		return nil, err
	}
	defer storage.Close()
	vault, ok := storage.(VaultStorage)
	if !ok {
		return nil, fmt.Errorf("chat.Import: storage does not expose vault")
	}

	// 1. Recreate conversation with fresh ID + current timestamps.
	now := s.Now()
	conv := &domain.Conversation{
		ID:           s.NewID(),
		AccountUUID:  accountUUID,
		Title:        bundle.Conversation.Title,
		Model:        bundle.Conversation.Model,
		SystemPrompt: bundle.Conversation.SystemPrompt,
		Archived:     bundle.Conversation.Archived,
		CreatedAt:    now,
		UpdatedAt:    now,
	}
	if err := storage.CreateConversation(ctx, conv); err != nil {
		return nil, fmt.Errorf("create conversation: %w", err)
	}

	// 2. Materialise attachments (write bytes via vault + insert row).
	// Build oldID → newID map so message blocks can be rewritten.
	attMap := map[string]string{}
	for _, ea := range bundle.Attachments {
		newID := s.NewID()
		attMap[ea.ID] = newID

		if ea.Base64Bytes != "" {
			bytes, err := base64.StdEncoding.DecodeString(ea.Base64Bytes)
			if err != nil {
				return nil, fmt.Errorf("decode attachment %s: %w", ea.ID, err)
			}
			path, nonce, err := vault.VaultWrite(ctx, newID, bytes)
			if err != nil {
				return nil, fmt.Errorf("vault write: %w", err)
			}
			row := &domain.Attachment{
				ID: newID, ConversationID: conv.ID,
				Kind: domain.AttachmentKind(ea.Kind),
				Filename: ea.Filename, MediaType: ea.MediaType,
				SizeBytes: ea.SizeBytes,
				FilePath: path, NonceHex: nonce,
				CreatedAt: now,
			}
			if err := storage.CreateAttachment(ctx, accountUUID, row); err != nil {
				return nil, fmt.Errorf("persist attachment row: %w", err)
			}
		}
	}

	// 3. Replay messages with rewritten attachment IDs.
	for _, em := range bundle.Messages {
		msg := &domain.Message{
			ID:             s.NewID(),
			ConversationID: conv.ID,
			Role:           domain.Role(em.Role),
			InputTokens:    em.InputTokens,
			OutputTokens:   em.OutputTokens,
			StopReason:     em.StopReason,
			CreatedAt:      em.CreatedAt,
		}
		for _, eb := range em.Content {
			b := domain.ContentBlock{
				Kind: domain.ContentBlockKind(eb.Kind),
				Text: eb.Text, MediaType: eb.MediaType,
			}
			if eb.AttachmentID != "" {
				b.AttachmentID = attMap[eb.AttachmentID]
			}
			msg.Content = append(msg.Content, b)
		}
		if err := storage.AppendMessage(ctx, accountUUID, msg); err != nil {
			return nil, fmt.Errorf("append message %s: %w", em.ID, err)
		}
	}
	return conv, nil
}
