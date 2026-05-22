package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/usecase/chat"
)

// runChatConversations dispatches `csw chat conversations <sub>`.
func runChatConversations(ctx context.Context, svc *chat.Service, accountNum int, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw chat conversations <list|create|load|rename|delete|export|import> ...")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "list":
		return runConvList(ctx, svc, accountNum, rest)
	case "create":
		return runConvCreate(ctx, svc, accountNum, rest)
	case "load":
		return runConvLoad(ctx, svc, accountNum, rest)
	case "rename":
		return runConvRename(ctx, svc, accountNum, rest)
	case "delete":
		return runConvDelete(ctx, svc, accountNum, rest)
	case "export":
		return runChatExport(ctx, svc, accountNum, rest)
	case "import":
		return runChatImport(ctx, svc, accountNum, rest)
	default:
		return fmt.Errorf("unknown conversations subcommand: %s", sub)
	}
}

// --- DTOs that round-trip on the wire ---

type conversationOut struct {
	ID           string    `json:"id"`
	AccountUUID  string    `json:"account_uuid"`
	Title        string    `json:"title"`
	Model        string    `json:"model"`
	SystemPrompt string    `json:"system_prompt,omitempty"`
	Archived     bool      `json:"archived"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}

func toConvOut(c domain.Conversation) conversationOut {
	return conversationOut{
		ID: c.ID, AccountUUID: c.AccountUUID, Title: c.Title, Model: c.Model,
		SystemPrompt: c.SystemPrompt, Archived: c.Archived,
		CreatedAt: c.CreatedAt, UpdatedAt: c.UpdatedAt,
	}
}

type messageOut struct {
	ID             string         `json:"id"`
	ConversationID string         `json:"conversation_id"`
	Role           string         `json:"role"`
	Content        []blockOut     `json:"content"`
	InputTokens    int            `json:"input_tokens"`
	OutputTokens   int            `json:"output_tokens"`
	StopReason     string         `json:"stop_reason,omitempty"`
	CreatedAt      time.Time      `json:"created_at"`
}

type blockOut struct {
	Kind         string `json:"kind"`
	Text         string `json:"text,omitempty"`
	AttachmentID string `json:"attachment_id,omitempty"`
	MediaType    string `json:"media_type,omitempty"`
}

func toMsgOut(m domain.Message) messageOut {
	blocks := make([]blockOut, 0, len(m.Content))
	for _, b := range m.Content {
		blocks = append(blocks, blockOut{
			Kind:         string(b.Kind),
			Text:         b.Text,
			AttachmentID: b.AttachmentID,
			MediaType:    b.MediaType,
		})
	}
	return messageOut{
		ID: m.ID, ConversationID: m.ConversationID, Role: string(m.Role),
		Content: blocks,
		InputTokens: m.InputTokens, OutputTokens: m.OutputTokens,
		StopReason: m.StopReason, CreatedAt: m.CreatedAt,
	}
}

// --- Handlers ---

func runConvList(ctx context.Context, svc *chat.Service, accountNum int, args []string) error {
	fs := flag.NewFlagSet("list", flag.ContinueOnError)
	_ = fs.Bool("json", true, "machine-readable output (default true)")
	_ = fs.Parse(args)

	convs, err := svc.ListConversations(ctx, accountNum)
	if err != nil {
		return err
	}
	out := make([]conversationOut, 0, len(convs))
	for _, c := range convs {
		out = append(out, toConvOut(c))
	}
	return writeJSON(out)
}

func runConvCreate(ctx context.Context, svc *chat.Service, accountNum int, args []string) error {
	fs := flag.NewFlagSet("create", flag.ContinueOnError)
	model := fs.String("model", "claude-sonnet-4-6", "model id")
	title := fs.String("title", "", "conversation title")
	systemFromStdin := fs.Bool("system-prompt-stdin", false, "read system prompt from stdin")
	if err := fs.Parse(args); err != nil {
		return err
	}
	systemPrompt := ""
	if *systemFromStdin {
		raw, err := io.ReadAll(os.Stdin)
		if err != nil {
			return fmt.Errorf("read system prompt: %w", err)
		}
		systemPrompt = string(raw)
	}
	c, err := svc.CreateConversation(ctx, accountNum, *model, systemPrompt, *title)
	if err != nil {
		return err
	}
	return writeJSON(toConvOut(*c))
}

func runConvLoad(ctx context.Context, svc *chat.Service, accountNum int, args []string) error {
	if len(args) < 1 {
		return errors.New("usage: csw chat conversations load <conv-id> [--json]")
	}
	convID := args[0]
	conv, msgs, err := svc.LoadConversation(ctx, accountNum, convID)
	if err != nil {
		return err
	}
	outMsgs := make([]messageOut, 0, len(msgs))
	for _, m := range msgs {
		outMsgs = append(outMsgs, toMsgOut(m))
	}
	return writeJSON(struct {
		Conversation conversationOut `json:"conversation"`
		Messages     []messageOut    `json:"messages"`
	}{toConvOut(*conv), outMsgs})
}

func runConvRename(ctx context.Context, svc *chat.Service, accountNum int, args []string) error {
	if len(args) < 1 {
		return errors.New("usage: csw chat conversations rename <conv-id> --title T")
	}
	convID := args[0]
	fs := flag.NewFlagSet("rename", flag.ContinueOnError)
	title := fs.String("title", "", "new title")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if err := svc.RenameConversation(ctx, accountNum, convID, *title); err != nil {
		return err
	}
	return writeJSON(map[string]string{"id": convID, "title": *title})
}

func runConvDelete(ctx context.Context, svc *chat.Service, accountNum int, args []string) error {
	if len(args) < 1 {
		return errors.New("usage: csw chat conversations delete <conv-id>")
	}
	convID := args[0]
	if err := svc.DeleteConversation(ctx, accountNum, convID); err != nil {
		return err
	}
	return writeJSON(map[string]string{"id": convID, "status": "deleted"})
}

// writeJSON marshals v and prints to stdout with a trailing newline.
func writeJSON(v any) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}
