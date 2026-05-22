package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

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

	enc := json.NewEncoder(os.Stdout)

	outcome, err := svc.SendMessage(ctx, accountNum, convID, blocks)
	if err != nil {
		// Emit a structured error event on stdout so the widget surfaces
		// a nice in-bubble error instead of "csw exited 1: <raw stderr>".
		// Exit 0: the error is already part of the event stream the caller
		// is consuming, and a non-zero exit would cause Swift's Process
		// terminationHandler to throw on top of the already-surfaced event.
		_ = enc.Encode(setupErrorEvent(err))
		return nil
	}

	// Forward events line-by-line. Newline triggers OS-level flush on the
	// macOS pipe Swift reads from, so the widget sees deltas live.
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

// setupErrorEvent maps a pre-stream error from svc.SendMessage into the
// same streamEventOut shape the widget already knows how to render. Keeps
// the in-bubble error UX uniform whether failure comes from Anthropic
// streaming OR from token refresh / storage open / 4xx-before-stream.
func setupErrorEvent(err error) streamEventOut {
	code, retryAfter := classifyCLIError(err)
	return streamEventOut{
		Kind:         string(domain.StreamError),
		ErrorCode:    code,
		ErrorMessage: friendlyMessage(err, code),
		RetryAfterS:  retryAfter,
	}
}

// classifyCLIError extracts a stable error code from the various error
// types svc.SendMessage can return. Mirrors the streamEventKind taxonomy
// the widget already branches on.
func classifyCLIError(err error) (code string, retryAfter int) {
	if err == nil {
		return "", 0
	}
	if errors.Is(err, domain.ErrUnauthorized) {
		return "auth", 0
	}
	if errors.Is(err, domain.ErrTokenRefreshFailed) {
		return "auth", 0
	}
	if errors.Is(err, domain.ErrNotActive) {
		return "auth", 0
	}
	if errors.Is(err, domain.ErrConversationNotFound) || errors.Is(err, domain.ErrAccountMismatch) {
		return "not_found", 0
	}
	// Anthropic adapter wraps 4xx/5xx as *anthropic.httpErrorEvent which
	// also satisfies the error interface. Match by substring on the message
	// to avoid an import cycle just for type-assertion.
	msg := err.Error()
	switch {
	case strings.Contains(msg, "rate_limited"):
		return "rate_limited", parseRetryAfterFromMsg(msg)
	case strings.Contains(msg, "overloaded"):
		return "overloaded", 0
	case strings.Contains(msg, "auth"):
		return "auth", 0
	case strings.Contains(msg, "bad_request"):
		return "bad_request", 0
	}
	return "unknown", 0
}

// parseRetryAfterFromMsg digs an integer out of "...retry after Ns..." if
// the upstream adapter included one. Best-effort; returns 0 when missing.
func parseRetryAfterFromMsg(msg string) int {
	idx := strings.Index(msg, "retry_after_s=")
	if idx < 0 {
		return 0
	}
	tail := msg[idx+len("retry_after_s="):]
	end := 0
	for end < len(tail) && tail[end] >= '0' && tail[end] <= '9' {
		end++
	}
	if end == 0 {
		return 0
	}
	n, err := strconv.Atoi(tail[:end])
	if err != nil {
		return 0
	}
	return n
}

// friendlyMessage rewrites raw adapter errors into Vietnamese copy the
// widget can show in the error banner directly.
func friendlyMessage(err error, code string) string {
	switch code {
	case "rate_limited":
		return "Quota 5h đã đầy với tài khoản đang active. Đổi sang account khác hoặc chờ Anthropic reset."
	case "overloaded":
		return "Anthropic đang quá tải — thử lại sau vài giây."
	case "auth":
		return "OAuth token không hợp lệ — vào Settings → Verify Accounts để re-login."
	case "not_found":
		return "Đoạn chat không còn — refresh lại danh sách."
	case "bad_request":
		return "Anthropic từ chối request: " + err.Error()
	}
	return err.Error()
}

// exitCodeFor maps the classified code to the exit-code taxonomy spec'd
// in phase-05 (0 ok, 3 auth, 4 quota, 5 not found, else 1).
func exitCodeFor(err error) int {
	code, _ := classifyCLIError(err)
	switch code {
	case "auth":         return 3
	case "rate_limited": return 4
	case "not_found":    return 5
	}
	return 1
}
