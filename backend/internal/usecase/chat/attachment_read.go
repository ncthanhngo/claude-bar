package chat

import (
	"context"
	"errors"
	"fmt"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// ReadAttachment fetches the attachment row + decrypts the file bytes via
// the vault. Used by the widget to lazy-preview historical attachments
// (chip in a 3-day-old message → user clicks → bytes streamed to a
// preview window). Returns ErrConversationNotFound if the id doesn't exist
// for the active account.
func (s *Service) ReadAttachment(
	ctx context.Context,
	accountNum int,
	attachmentID string,
) (*domain.Attachment, []byte, error) {
	if attachmentID == "" {
		return nil, nil, errors.New("chat: empty attachmentID")
	}
	_, accountUUID, storage, err := s.openForAccount(ctx, accountNum)
	if err != nil {
		return nil, nil, err
	}
	defer storage.Close()

	att, err := storage.GetAttachment(ctx, accountUUID, attachmentID)
	if err != nil {
		return nil, nil, err
	}

	vault, ok := storage.(VaultStorage)
	if !ok {
		return nil, nil, errors.New("chat: storage does not expose attachment vault")
	}
	plaintext, err := vault.VaultRead(ctx, att.ID, att.FilePath, att.NonceHex)
	if err != nil {
		return nil, nil, fmt.Errorf("decrypt attachment: %w", err)
	}
	return att, plaintext, nil
}
