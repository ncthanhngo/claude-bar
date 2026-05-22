package claudecli

import (
	"fmt"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// flattenHistory turns the structured ChatRequest into a single prompt
// string `claude -p` can consume on stdin. The format embeds prior turns
// as `[USER]:` / `[ASSISTANT]:` labeled blocks so the model treats it as
// an ongoing conversation. The latest user message is the final block —
// the assistant continues from there.
//
// Multimodal blocks (image / document) are referenced by filename inside
// the user block since `claude -p` text mode can't accept base64 inline.
// Phase 09 (or a follow-up) can switch to --input-format=stream-json for
// proper multi-message + multimodal pass-through.
func flattenHistory(req port.ChatRequest) string {
	var b strings.Builder

	if sp := strings.TrimSpace(req.SystemPrompt); sp != "" {
		b.WriteString("System prompt:\n")
		b.WriteString(sp)
		b.WriteString("\n\n")
	}

	// Walk every message in chronological order; the latest user message
	// becomes the bottom of the prompt that Claude responds to.
	for i, msg := range req.Messages {
		role := strings.ToUpper(string(msg.Role))
		if msg.Role == "" {
			role = "USER"
		}
		b.WriteString("[")
		b.WriteString(role)
		b.WriteString("]:\n")
		b.WriteString(flattenContent(msg.Content))
		if i < len(req.Messages)-1 {
			b.WriteString("\n\n")
		} else {
			b.WriteString("\n")
		}
	}
	return strings.TrimSpace(b.String())
}

// flattenContent renders one message's content blocks into plain text.
// Image / document references show up as `[file: image.png]` placeholders
// so the model knows an attachment existed even though we can't ship the
// bytes through `claude -p` text mode.
func flattenContent(blocks []domain.ContentBlock) string {
	var parts []string
	for _, b := range blocks {
		switch b.Kind {
		case domain.BlockText:
			t := strings.TrimSpace(b.Text)
			if t != "" {
				parts = append(parts, t)
			}
		case domain.BlockThinking:
			// Skip thinking — don't echo back prior reasoning trace, it's
			// noise for the model and bloats prompt cache invalidation.
			continue
		case domain.BlockImage, domain.BlockDocument:
			label := b.MediaType
			if label == "" {
				label = string(b.Kind)
			}
			parts = append(parts, fmt.Sprintf("[file: %s · id=%s]", label, b.AttachmentID))
		case domain.BlockToolUse:
			// Tools aren't part of the chat surface yet; surface a marker.
			parts = append(parts, fmt.Sprintf("[tool_use: %s]", b.ToolName))
		}
	}
	return strings.Join(parts, "\n\n")
}
