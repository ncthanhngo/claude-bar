package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/soi/claude-swap-widget/backend/internal/usecase/chat"
)

// runChatAttachmentRead writes the decrypted attachment bytes to stdout
// and the media type to stderr (so callers can parse it without polluting
// the binary payload on stdout). Used by the widget to lazy-load preview
// bytes for historical messages.
//
// Usage: `csw chat attachment read <attachment-id>`
// Exit 5 if the attachment isn't found.
func runChatAttachmentRead(ctx context.Context, svc *chat.Service, accountNum int, args []string) error {
	if len(args) < 1 {
		return errors.New("usage: csw chat attachment read <attachment-id>")
	}
	id := args[0]
	att, bytes, err := svc.ReadAttachment(ctx, accountNum, id)
	if err != nil {
		// Distinguish "not found" so the caller can react in the UI.
		if isNotFoundErr(err) {
			os.Exit(5)
		}
		return err
	}
	// Surface the media type on stderr so stdout stays binary-clean. Widget
	// reads stdout via runRaw + already knows MediaType from the row, but
	// piping consumers may want it directly.
	fmt.Fprintf(os.Stderr, "media-type: %s\n", att.MediaType)
	fmt.Fprintf(os.Stderr, "filename: %s\n", att.Filename)
	if _, err := io.Copy(os.Stdout, bytesReader(bytes)); err != nil {
		return fmt.Errorf("write stdout: %w", err)
	}
	return nil
}

// bytesReader is a tiny io.Reader over a byte slice — keeps the import
// surface small (no bytes.NewReader) for one-shot use.
type bytesReader []byte

func (b bytesReader) Read(p []byte) (int, error) {
	n := copy(p, b)
	if n == 0 {
		return 0, io.EOF
	}
	return n, nil
}

func isNotFoundErr(err error) bool {
	if err == nil {
		return false
	}
	// domain.ErrConversationNotFound is what attachments_repo returns when
	// the row is missing (close-enough heuristic per phase 02 comment).
	msg := err.Error()
	return contains(msg, "conversation not found") || contains(msg, "attachment not found")
}

func contains(s, sub string) bool {
	if len(sub) > len(s) {
		return false
	}
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
