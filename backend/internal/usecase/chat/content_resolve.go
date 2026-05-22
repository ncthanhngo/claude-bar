package chat

import (
	"context"
	"encoding/base64"
	"fmt"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// inflateAttachments walks every ContentBlock and, for image / document
// blocks that reference an AttachmentID, fills the transient Base64Data
// field by reading + decrypting the file via the storage vault. Returns
// a copy of the slice (the original messages stay unchanged in DB form).
//
// MediaType on the block is overwritten from the attachment row when
// missing — UI sometimes only stores the AttachmentID and trusts the row.
func inflateAttachments(
	ctx context.Context,
	accountUUID string,
	vault VaultStorage,
	in []domain.Message,
) ([]domain.Message, error) {
	out := make([]domain.Message, len(in))
	for i, msg := range in {
		blocks := make([]domain.ContentBlock, len(msg.Content))
		for j, blk := range msg.Content {
			b := blk
			if needsInflate(b) {
				att, err := vault.GetAttachment(ctx, accountUUID, b.AttachmentID)
				if err != nil {
					return nil, fmt.Errorf("resolve attachment %s: %w", b.AttachmentID, err)
				}
				pt, err := vault.VaultRead(ctx, att.ID, att.FilePath, att.NonceHex)
				if err != nil {
					return nil, fmt.Errorf("decrypt attachment %s: %w", b.AttachmentID, err)
				}
				b.Base64Data = base64.StdEncoding.EncodeToString(pt)
				if b.MediaType == "" {
					b.MediaType = att.MediaType
				}
			}
			blocks[j] = b
		}
		copyMsg := msg
		copyMsg.Content = blocks
		out[i] = copyMsg
	}
	return out, nil
}

func needsInflate(b domain.ContentBlock) bool {
	if b.AttachmentID == "" {
		return false
	}
	return b.Kind == domain.BlockImage || b.Kind == domain.BlockDocument
}
