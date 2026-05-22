package chat

import (
	"context"
	"encoding/base64"
	"fmt"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// ExportBundleSchema is the on-the-wire JSON shape of `csw chat
// conversations export`. Bumping the version is a breaking change.
const ExportBundleSchema = 1

// ExportBundle is the canonical structure surfaced over stdout when the
// user runs `csw chat conversations export <id>`. It's JSON-roundtrippable
// — `ImportConversation` reads the same shape and recreates the row + any
// attachments in the active account's storage.
type ExportBundle struct {
	Schema       int                    `json:"schema"`
	ExportedAt   time.Time              `json:"exported_at"`
	Conversation ExportConversation     `json:"conversation"`
	Messages     []ExportMessage        `json:"messages"`
	Attachments  []ExportAttachment     `json:"attachments"`
}

type ExportConversation struct {
	ID           string    `json:"id"`
	Title        string    `json:"title"`
	Model        string    `json:"model"`
	SystemPrompt string    `json:"system_prompt"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
	Archived     bool      `json:"archived"`
}

type ExportMessage struct {
	ID           string                 `json:"id"`
	Role         string                 `json:"role"`
	Content      []ExportContentBlock   `json:"content"`
	InputTokens  int                    `json:"input_tokens,omitempty"`
	OutputTokens int                    `json:"output_tokens,omitempty"`
	StopReason   string                 `json:"stop_reason,omitempty"`
	CreatedAt    time.Time              `json:"created_at"`
}

type ExportContentBlock struct {
	Kind         string `json:"kind"`
	Text         string `json:"text,omitempty"`
	AttachmentID string `json:"attachment_id,omitempty"`
	MediaType    string `json:"media_type,omitempty"`
}

// ExportAttachment carries the encrypted-then-base64-encoded plaintext.
// Yes — export decrypts the vault, so the bundle is sensitive. The CLI
// surface warns users explicitly. `IncludeBytes=false` mode omits the
// Base64Bytes field for metadata-only export.
type ExportAttachment struct {
	ID         string `json:"id"`
	Filename   string `json:"filename"`
	Kind       string `json:"kind"`
	MediaType  string `json:"media_type"`
	SizeBytes  int64  `json:"size_bytes"`
	Base64Bytes string `json:"base64_bytes,omitempty"`
}

// ExportConversation pulls the full conversation + messages + (optionally)
// decrypted attachment bytes into an ExportBundle. The caller decides
// whether to inline bytes via `includeBytes`.
func (s *Service) ExportConversation(
	ctx context.Context,
	accountNum int,
	conversationID string,
	includeBytes bool,
) (*ExportBundle, error) {
	_, accountUUID, storage, err := s.openForAccount(ctx, accountNum)
	if err != nil {
		return nil, err
	}
	defer storage.Close()

	conv, err := storage.GetConversation(ctx, accountUUID, conversationID)
	if err != nil {
		return nil, err
	}
	msgs, err := storage.ListMessages(ctx, accountUUID, conversationID)
	if err != nil {
		return nil, err
	}

	bundle := &ExportBundle{
		Schema:     ExportBundleSchema,
		ExportedAt: s.Now(),
		Conversation: ExportConversation{
			ID: conv.ID, Title: conv.Title, Model: conv.Model,
			SystemPrompt: conv.SystemPrompt,
			CreatedAt: conv.CreatedAt, UpdatedAt: conv.UpdatedAt,
			Archived: conv.Archived,
		},
	}

	seenAtt := map[string]bool{}
	for _, m := range msgs {
		em := ExportMessage{
			ID: m.ID, Role: string(m.Role),
			InputTokens: m.InputTokens, OutputTokens: m.OutputTokens,
			StopReason: m.StopReason, CreatedAt: m.CreatedAt,
		}
		for _, b := range m.Content {
			em.Content = append(em.Content, ExportContentBlock{
				Kind: string(b.Kind), Text: b.Text,
				AttachmentID: b.AttachmentID, MediaType: b.MediaType,
			})
			if b.AttachmentID != "" && !seenAtt[b.AttachmentID] {
				seenAtt[b.AttachmentID] = true
				if exp, err := s.collectAttachment(ctx, accountUUID, storage, b.AttachmentID, includeBytes); err == nil {
					bundle.Attachments = append(bundle.Attachments, exp)
				}
			}
		}
		bundle.Messages = append(bundle.Messages, em)
	}
	return bundle, nil
}

func (s *Service) collectAttachment(
	ctx context.Context,
	accountUUID string,
	storage interface {
		GetAttachment(ctx context.Context, accountUUID, id string) (*domain.Attachment, error)
	},
	id string,
	includeBytes bool,
) (ExportAttachment, error) {
	att, err := storage.GetAttachment(ctx, accountUUID, id)
	if err != nil {
		return ExportAttachment{}, err
	}
	out := ExportAttachment{
		ID: att.ID, Filename: att.Filename,
		Kind: string(att.Kind), MediaType: att.MediaType,
		SizeBytes: att.SizeBytes,
	}
	if !includeBytes {
		return out, nil
	}
	vault, ok := storage.(VaultStorage)
	if !ok {
		return out, fmt.Errorf("storage does not expose vault")
	}
	plaintext, err := vault.VaultRead(ctx, att.ID, att.FilePath, att.NonceHex)
	if err != nil {
		return out, err
	}
	out.Base64Bytes = base64.StdEncoding.EncodeToString(plaintext)
	return out, nil
}
