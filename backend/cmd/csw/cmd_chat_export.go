package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/soi/claude-swap-widget/backend/internal/usecase/chat"
)

// runChatExport exports a single conversation as JSON on stdout. The
// `--with-attachments` flag opts in to inlining decrypted attachment bytes
// (base64); without it, only metadata. The user-facing copy on the Settings
// button warns this is unencrypted.
func runChatExport(ctx context.Context, svc *chat.Service, accountNum int, args []string) error {
	if len(args) < 1 {
		return errors.New("usage: csw chat conversations export <conv-id> [--with-attachments]")
	}
	convID := args[0]

	fs := flag.NewFlagSet("export", flag.ContinueOnError)
	withAtt := fs.Bool("with-attachments", false, "inline decrypted attachment bytes (base64)")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}

	bundle, err := svc.ExportConversation(ctx, accountNum, convID, *withAtt)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(bundle)
}

// runChatImport reads a bundle JSON from stdin and recreates it in the
// active account. Returns the new conversation's ID.
func runChatImport(ctx context.Context, svc *chat.Service, accountNum int, args []string) error {
	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		return fmt.Errorf("read stdin: %w", err)
	}
	if len(raw) == 0 {
		return errors.New("import: empty stdin (pipe a bundle JSON)")
	}
	var bundle chat.ExportBundle
	if err := json.Unmarshal(raw, &bundle); err != nil {
		return fmt.Errorf("decode bundle: %w", err)
	}
	conv, err := svc.ImportConversation(ctx, accountNum, &bundle)
	if err != nil {
		return err
	}
	return writeJSON(map[string]string{"id": conv.ID, "title": conv.Title, "status": "imported"})
}
