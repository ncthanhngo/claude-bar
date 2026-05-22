// Package anthropic implements port.ChatClient against the Anthropic
// Messages API using OAuth Bearer auth. The adapter is pure I/O — no
// retry, no caching, no business policy. Errors map to domain sentinels
// so the usecase can decide what to do.
package anthropic

import (
	"encoding/json"
	"fmt"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// Wire shapes for POST /v1/messages. Field names match Anthropic spec.

type messagesBody struct {
	Model     string     `json:"model"`
	System    []sysBlock `json:"system,omitempty"`
	Messages  []msgBody  `json:"messages"`
	MaxTokens int        `json:"max_tokens"`
	Stream    bool       `json:"stream"`
}

type sysBlock struct {
	Type         string    `json:"type"` // always "text"
	Text         string    `json:"text"`
	CacheControl *cacheCtl `json:"cache_control,omitempty"`
}

type cacheCtl struct {
	Type string `json:"type"` // "ephemeral"
}

type msgBody struct {
	Role    string         `json:"role"`
	Content []contentBlock `json:"content"`
}

type contentBlock struct {
	Type   string       `json:"type"` // "text" | "image" | "document"
	Text   string       `json:"text,omitempty"`
	Source *sourceBlock `json:"source,omitempty"`
}

type sourceBlock struct {
	Type      string `json:"type"` // "base64"
	MediaType string `json:"media_type"`
	Data      string `json:"data"`
}

// encodeRequest builds the JSON body for /v1/messages from the port-level
// ChatRequest. System prompt gets cache_control=ephemeral so long prefix is
// reused across turns. Multimodal blocks require the usecase to have already
// populated Base64Data on each ContentBlock (decrypted from disk).
func encodeRequest(req port.ChatRequest) ([]byte, error) {
	maxTokens := req.MaxTokens
	if maxTokens <= 0 {
		maxTokens = 4096
	}
	body := messagesBody{
		Model:     req.Model,
		MaxTokens: maxTokens,
		Stream:    req.Stream,
	}
	if s := req.SystemPrompt; s != "" {
		body.System = []sysBlock{{
			Type:         "text",
			Text:         s,
			CacheControl: &cacheCtl{Type: "ephemeral"},
		}}
	}
	body.Messages = make([]msgBody, 0, len(req.Messages))
	for _, m := range req.Messages {
		blocks, err := mapContentBlocks(m.Content)
		if err != nil {
			return nil, fmt.Errorf("encode message %s: %w", m.ID, err)
		}
		body.Messages = append(body.Messages, msgBody{
			Role:    string(m.Role),
			Content: blocks,
		})
	}
	return json.Marshal(body)
}

func mapContentBlocks(blocks []domain.ContentBlock) ([]contentBlock, error) {
	out := make([]contentBlock, 0, len(blocks))
	for _, b := range blocks {
		if err := b.Validate(); err != nil {
			return nil, err
		}
		switch b.Kind {
		case domain.BlockText:
			out = append(out, contentBlock{Type: "text", Text: b.Text})
		case domain.BlockThinking:
			// Don't echo prior thinking back to Anthropic — they don't accept
			// thinking blocks in user-side history. Skip silently.
			continue
		case domain.BlockImage:
			if b.Base64Data == "" {
				return nil, fmt.Errorf("image block %q missing Base64Data — usecase forgot to decode", b.AttachmentID)
			}
			out = append(out, contentBlock{
				Type: "image",
				Source: &sourceBlock{
					Type: "base64", MediaType: b.MediaType, Data: b.Base64Data,
				},
			})
		case domain.BlockDocument:
			if b.Base64Data == "" {
				return nil, fmt.Errorf("document block %q missing Base64Data", b.AttachmentID)
			}
			out = append(out, contentBlock{
				Type: "document",
				Source: &sourceBlock{
					Type: "base64", MediaType: b.MediaType, Data: b.Base64Data,
				},
			})
		case domain.BlockToolUse:
			// Tool use round-trip isn't wired in MVP — skip for now. Phase 09+
			// will add a tool_use ↔ tool_result mapping if needed.
			continue
		default:
			return nil, fmt.Errorf("unsupported block kind %q", b.Kind)
		}
	}
	return out, nil
}
