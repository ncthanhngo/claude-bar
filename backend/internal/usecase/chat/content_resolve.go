package chat

import (
	"context"
	"encoding/base64"
	"fmt"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// inflateAttachments walks every ContentBlock and, for blocks that reference
// an AttachmentID, looks up the attachment row + decrypts the file via the
// vault, then rewrites the block into the right shape for Anthropic:
//   - image  → BlockImage with Base64Data + MediaType set
//   - pdf    → BlockDocument with Base64Data + MediaType set
//   - text   → BlockText wrapped as <file name="..."> ... </file>
//
// The composer always sends BlockImage for attachment refs (it can't know
// the kind without reading the row), so this resolver is the single place
// where attachment kind dictates the wire shape.
func inflateAttachments(
	ctx context.Context,
	accountUUID string,
	vault VaultStorage,
	in []domain.Message,
) ([]domain.Message, error) {
	out := make([]domain.Message, len(in))
	for i, msg := range in {
		blocks := make([]domain.ContentBlock, 0, len(msg.Content))
		for _, blk := range msg.Content {
			if blk.AttachmentID == "" {
				blocks = append(blocks, blk)
				continue
			}
			resolved, err := resolveAttachmentBlock(ctx, accountUUID, vault, blk)
			if err != nil {
				return nil, err
			}
			blocks = append(blocks, resolved)
		}
		copyMsg := msg
		copyMsg.Content = blocks
		out[i] = copyMsg
	}
	return out, nil
}

func resolveAttachmentBlock(
	ctx context.Context,
	accountUUID string,
	vault VaultStorage,
	blk domain.ContentBlock,
) (domain.ContentBlock, error) {
	att, err := vault.GetAttachment(ctx, accountUUID, blk.AttachmentID)
	if err != nil {
		return blk, fmt.Errorf("resolve attachment %s: %w", blk.AttachmentID, err)
	}
	plaintext, err := vault.VaultRead(ctx, att.ID, att.FilePath, att.NonceHex)
	if err != nil {
		return blk, fmt.Errorf("decrypt attachment %s: %w", blk.AttachmentID, err)
	}

	switch att.Kind {
	case domain.AttachImage:
		return domain.ContentBlock{
			Kind:         domain.BlockImage,
			AttachmentID: att.ID,
			MediaType:    att.MediaType,
			Base64Data:   base64.StdEncoding.EncodeToString(plaintext),
		}, nil

	case domain.AttachPDF:
		return domain.ContentBlock{
			Kind:         domain.BlockDocument,
			AttachmentID: att.ID,
			MediaType:    att.MediaType,
			Base64Data:   base64.StdEncoding.EncodeToString(plaintext),
		}, nil

	case domain.AttachText:
		// Wrap in <file name="..."> so the model sees the filename context.
		// Mirrors the convention Anthropic suggests for non-binary inline
		// content in prompts.
		var b strings.Builder
		b.WriteString("<file name=\"")
		b.WriteString(escapeAttrValue(att.Filename))
		b.WriteString("\">\n")
		b.Write(plaintext)
		if !strings.HasSuffix(string(plaintext), "\n") {
			b.WriteString("\n")
		}
		b.WriteString("</file>")
		return domain.ContentBlock{
			Kind: domain.BlockText,
			Text: b.String(),
		}, nil

	default:
		return blk, fmt.Errorf("unsupported attachment kind %q", att.Kind)
	}
}

// escapeAttrValue escapes the minimal set of characters needed to keep an
// HTML/XML-style attribute well-formed when wrapping a filename.
func escapeAttrValue(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "\"", "&quot;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	return s
}
