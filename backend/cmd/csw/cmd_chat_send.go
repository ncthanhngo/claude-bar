package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/usecase/chat"
)

// sendStdinInput is the shape the widget pipes on stdin for `csw chat send`.
// Keeps user-supplied text out of argv (visible to `ps`).
type sendStdinInput struct {
	Text          string   `json:"text"`
	AttachmentIDs []string `json:"attachment_ids,omitempty"`
}

// streamEventOut is the JSON-per-line shape we emit on stdout.
type streamEventOut struct {
	Kind         string `json:"kind"`
	Text         string `json:"text,omitempty"`
	InputTokens  int    `json:"input_tokens,omitempty"`
	OutputTokens int    `json:"output_tokens,omitempty"`
	StopReason   string `json:"stop_reason,omitempty"`
	ErrorCode    string `json:"error_code,omitempty"`
	ErrorMessage string `json:"error_message,omitempty"`
	RetryAfterS  int    `json:"retry_after_s,omitempty"`
	MessageID    string `json:"message_id,omitempty"`
}

// runChatSend streams a chat reply to stdout, one JSON event per line.
// stdin payload: {"text":"…", "attachment_ids":["…"]}.
//
// Exit code is conveyed via `chatSendExit` (return value of this function
// becomes a non-nil error → main exits 1; ctx cancellation exits 130).
func runChatSend(ctx context.Context, svc *chat.Service, accountNum int, args []string) error {
	if len(args) < 1 {
		return errors.New("usage: csw chat send <conv-id> < stdin-json")
	}
	convID := args[0]

	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		return fmt.Errorf("read stdin: %w", err)
	}
	var input sendStdinInput
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &input); err != nil {
			return fmt.Errorf("decode stdin: %w", err)
		}
	}

	blocks := buildBlocks(input)
	if len(blocks) == 0 {
		return errors.New("empty user message: stdin needs {text or attachment_ids}")
	}

	outcome, err := svc.SendMessage(ctx, accountNum, convID, blocks)
	if err != nil {
		return err
	}

	// Forward events line-by-line. Newline triggers OS-level flush on the
	// macOS pipe Swift reads from, so the widget sees deltas live.
	enc := json.NewEncoder(os.Stdout)
	for ev := range outcome.Events {
		if err := enc.Encode(toStreamEventOut(ev, outcome.UserMessageID)); err != nil {
			return fmt.Errorf("encode event: %w", err)
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return nil
}

func buildBlocks(in sendStdinInput) []domain.ContentBlock {
	blocks := []domain.ContentBlock{}
	for _, id := range in.AttachmentIDs {
		// Kind is provisional — usecase inflater overwrites MediaType from
		// the attachment row; the adapter resolves the right Anthropic shape
		// (image vs document) from the eventual MediaType.
		blocks = append(blocks, domain.ContentBlock{Kind: domain.BlockImage, AttachmentID: id})
	}
	if in.Text != "" {
		blocks = append(blocks, domain.ContentBlock{Kind: domain.BlockText, Text: in.Text})
	}
	return blocks
}

func toStreamEventOut(ev domain.ChatStreamEvent, userMsgID string) streamEventOut {
	out := streamEventOut{Kind: string(ev.Kind)}
	switch ev.Kind {
	case domain.StreamTextDelta, domain.StreamThinkingDelta:
		out.Text = ev.Text
	case domain.StreamUsage:
		out.InputTokens = ev.InputTokens
		out.OutputTokens = ev.OutputTokens
	case domain.StreamDone:
		out.StopReason = ev.StopReason
		out.InputTokens = ev.InputTokens
		out.OutputTokens = ev.OutputTokens
		out.MessageID = userMsgID
	case domain.StreamError:
		out.ErrorCode = ev.ErrorCode
		out.ErrorMessage = ev.ErrorMessage
		out.RetryAfterS = ev.RetryAfterS
	}
	return out
}
