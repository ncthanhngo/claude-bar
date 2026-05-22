package domain

import (
	"errors"
	"testing"
	"time"
)

func TestContentBlockValidate(t *testing.T) {
	cases := []struct {
		name    string
		block   ContentBlock
		wantErr bool
	}{
		{"text ok", ContentBlock{Kind: BlockText, Text: "hello"}, false},
		{"text empty", ContentBlock{Kind: BlockText}, true},
		{"thinking ok", ContentBlock{Kind: BlockThinking, Text: "let me reason"}, false},
		{"image ok", ContentBlock{Kind: BlockImage, AttachmentID: "a1", MediaType: "image/png"}, false},
		{"image missing media type", ContentBlock{Kind: BlockImage, AttachmentID: "a1"}, true},
		{"image missing attachment", ContentBlock{Kind: BlockImage, MediaType: "image/png"}, true},
		{"document ok", ContentBlock{Kind: BlockDocument, AttachmentID: "a2", MediaType: "application/pdf"}, false},
		{"tool_use ok", ContentBlock{Kind: BlockToolUse, ToolName: "search"}, false},
		{"tool_use missing name", ContentBlock{Kind: BlockToolUse}, true},
		{"unknown kind", ContentBlock{Kind: "garbage", Text: "x"}, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.block.Validate()
			if tc.wantErr && err == nil {
				t.Fatal("expected error, got nil")
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("expected nil, got %v", err)
			}
			if tc.wantErr && err != nil && !errors.Is(err, ErrInvalidContentBlock) {
				t.Fatalf("expected ErrInvalidContentBlock, got %v", err)
			}
		})
	}
}

func TestMessagePlainText(t *testing.T) {
	m := Message{
		ID:   "m1",
		Role: RoleAssistant,
		Content: []ContentBlock{
			{Kind: BlockText, Text: "Hello "},
			{Kind: BlockImage, AttachmentID: "a1", MediaType: "image/png"},
			{Kind: BlockText, Text: "world"},
		},
		CreatedAt: time.Now(),
	}
	if got := m.PlainText(); got != "Hello world" {
		t.Fatalf("PlainText = %q, want %q", got, "Hello world")
	}
}

func TestConversationIsForAccount(t *testing.T) {
	c := Conversation{ID: "c1", AccountUUID: "acc-uuid-A"}
	if !c.IsForAccount("acc-uuid-A") {
		t.Fatal("IsForAccount should return true for matching UUID")
	}
	if c.IsForAccount("acc-uuid-B") {
		t.Fatal("IsForAccount should return false for non-matching UUID")
	}
}
