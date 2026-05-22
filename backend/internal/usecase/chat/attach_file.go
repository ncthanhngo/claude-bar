package chat

import (
	"context"
	"errors"
	"fmt"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// Size caps per attachment kind. Anthropic accepts larger payloads but the
// chat UX targets quick turns — bigger files belong in /v1/files (out of
// MVP scope) or a future "summarise this PDF" flow.
const (
	MaxImageBytes = 5 * 1024 * 1024  // 5 MB
	MaxPDFBytes   = 20 * 1024 * 1024 // 20 MB
	MaxTextBytes  = 256 * 1024       // 256 KB
)

// AttachFile encrypts the file bytes to disk via the vault and inserts an
// attachment row. The returned Attachment has FilePath + NonceHex set so
// a subsequent SendMessage can resolve the row back to bytes for upload.
func (s *Service) AttachFile(
	ctx context.Context,
	accountNum int,
	conversationID, filename, mediaType string,
	kind domain.AttachmentKind,
	plaintext []byte,
) (*domain.Attachment, error) {
	if err := capForKind(kind, len(plaintext)); err != nil {
		return nil, err
	}

	_, accountUUID, storage, err := s.openForAccount(ctx, accountNum)
	if err != nil {
		return nil, err
	}
	defer storage.Close()

	vault, ok := storage.(VaultStorage)
	if !ok {
		return nil, errors.New("chat: storage does not expose attachment vault")
	}

	// Confirm the conversation belongs to the active account before we
	// write bytes to disk — avoids leaving an orphaned .enc file.
	conv, err := storage.GetConversation(ctx, accountUUID, conversationID)
	if err != nil {
		return nil, err
	}

	id := s.NewID()
	path, nonce, err := vault.VaultWrite(ctx, id, plaintext)
	if err != nil {
		return nil, fmt.Errorf("vault write: %w", err)
	}

	att := &domain.Attachment{
		ID:             id,
		ConversationID: conv.ID,
		Kind:           kind,
		Filename:       filename,
		MediaType:      mediaType,
		SizeBytes:      int64(len(plaintext)),
		FilePath:       path,
		NonceHex:       nonce,
		CreatedAt:      s.Now(),
	}
	if err := storage.CreateAttachment(ctx, accountUUID, att); err != nil {
		return nil, fmt.Errorf("persist attachment row: %w", err)
	}
	return att, nil
}

func capForKind(kind domain.AttachmentKind, size int) error {
	limit := 0
	switch kind {
	case domain.AttachImage:
		limit = MaxImageBytes
	case domain.AttachPDF:
		limit = MaxPDFBytes
	case domain.AttachText:
		limit = MaxTextBytes
	default:
		return fmt.Errorf("chat: unsupported attachment kind %q", kind)
	}
	if size > limit {
		return fmt.Errorf("%w (kind=%s size=%d limit=%d)",
			domain.ErrAttachmentTooLarge, kind, size, limit)
	}
	return nil
}
