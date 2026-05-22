package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/usecase/chat"
)

// attachmentOut is the JSON shape we return after a successful upload.
type attachmentOut struct {
	ID             string `json:"id"`
	ConversationID string `json:"conversation_id"`
	Kind           string `json:"kind"`
	Filename       string `json:"filename"`
	MediaType      string `json:"media_type"`
	SizeBytes      int64  `json:"size_bytes"`
}

// runChatAttach reads file bytes from stdin and creates an encrypted
// attachment row + .enc file via the vault. Returns the attachment id
// the widget passes to `csw chat send`'s attachment_ids array later.
func runChatAttach(ctx context.Context, svc *chat.Service, accountNum int, args []string) error {
	if len(args) < 1 {
		return errors.New("usage: csw chat attach <conv-id> --filename F --media-type M < stdin-bytes")
	}
	convID := args[0]

	fs := flag.NewFlagSet("attach", flag.ContinueOnError)
	filename := fs.String("filename", "", "original filename")
	mediaType := fs.String("media-type", "", "MIME type (image/png, application/pdf, text/markdown…)")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if *filename == "" || *mediaType == "" {
		return errors.New("--filename and --media-type are required")
	}

	plaintext, err := io.ReadAll(os.Stdin)
	if err != nil {
		return fmt.Errorf("read stdin: %w", err)
	}
	if len(plaintext) == 0 {
		return errors.New("no bytes on stdin")
	}

	kind := kindFromMediaType(*mediaType)
	att, err := svc.AttachFile(ctx, accountNum, convID, *filename, *mediaType, kind, plaintext)
	if err != nil {
		return err
	}
	return writeJSON(attachmentOut{
		ID: att.ID, ConversationID: att.ConversationID,
		Kind: string(att.Kind), Filename: att.Filename,
		MediaType: att.MediaType, SizeBytes: att.SizeBytes,
	})
}

// kindFromMediaType collapses MIME types to the small AttachmentKind enum
// the size cap uses. Unknown types map to text — safest small-cap default.
func kindFromMediaType(mt string) domain.AttachmentKind {
	mt = strings.ToLower(mt)
	switch {
	case strings.HasPrefix(mt, "image/"):
		return domain.AttachImage
	case mt == "application/pdf":
		return domain.AttachPDF
	default:
		return domain.AttachText
	}
}
