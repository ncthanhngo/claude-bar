package briefing

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// DraftInput is the per-signal context the drafter turns into a suggested
// action. Fields mirror the widget's WorkspaceSignalDTO plus an optional
// refine instruction for the "Hỏi thêm" follow-up.
type DraftInput struct {
	Kind          string `json:"kind"`
	Source        string `json:"source"`
	Title         string `json:"title"`
	Context       string `json:"context"`
	Actor         string `json:"actor"`
	Instruction   string `json:"instruction,omitempty"`   // refine ask, e.g. "ngắn gọn hơn"
	PreviousDraft string `json:"previousDraft,omitempty"` // the draft being refined
}

// Draft is the drafter's output: a ready-to-send body plus a one-line rationale.
type Draft struct {
	Draft     string `json:"draft"`
	Rationale string `json:"rationale"`
}

// DraftAction asks Claude for a suggested action body for one signal. Returns a
// Draft, or an error the caller surfaces inline. No MCP access — drafts from the
// signal context alone (full-thread fetch is a later refinement).
func DraftAction(ctx context.Context, r *ClaudeRunner, in DraftInput) (*Draft, error) {
	raw, err := r.RunText(ctx, buildDraftPrompt(in))
	if err != nil {
		return nil, err
	}
	var d Draft
	if err := json.Unmarshal([]byte(extractJSONObject(raw)), &d); err != nil {
		// Model ignored the JSON contract — treat the whole reply as the draft
		// so the user still gets something editable rather than an error.
		return &Draft{Draft: strings.TrimSpace(raw)}, nil
	}
	return &d, nil
}

func buildDraftPrompt(in DraftInput) string {
	var b strings.Builder
	b.WriteString("Bạn là trợ lý soạn nhanh phản hồi cho công việc. ")
	b.WriteString(kindInstruction(in.Kind))
	b.WriteString("\n\nNgữ cảnh:\n")
	fmt.Fprintf(&b, "- Nguồn: %s\n", in.Source)
	if in.Actor != "" {
		fmt.Fprintf(&b, "- Người liên quan: %s\n", in.Actor)
	}
	if in.Title != "" {
		fmt.Fprintf(&b, "- Việc: %s\n", in.Title)
	}
	if in.Context != "" {
		fmt.Fprintf(&b, "- Nội dung: %s\n", in.Context)
	}
	if in.PreviousDraft != "" {
		fmt.Fprintf(&b, "\nBản nháp trước:\n%s\n", in.PreviousDraft)
	}
	if in.Instruction != "" {
		fmt.Fprintf(&b, "\nYêu cầu chỉnh: %s\n", in.Instruction)
	}
	b.WriteString("\nTrả về CHỈ một JSON object, không markdown, không bình luận, dạng:\n")
	b.WriteString(`{"draft": "<nội dung gửi đi>", "rationale": "<một dòng vì sao>"}`)
	b.WriteString("\nViết tiếng Việt tự nhiên, đúng văn phong công việc, ngắn gọn.")
	return b.String()
}

func kindInstruction(kind string) string {
	switch kind {
	case "mention", "dm":
		return "Soạn một câu trả lời ngắn, lịch sự cho tin nhắn Slack này."
	case "email":
		return "Soạn nội dung email trả lời ngắn gọn, lịch sự."
	case "task_due":
		return "Soạn một comment ngắn cập nhật/nhắc tiến độ cho task này."
	case "meeting_now", "meeting_next":
		return "Soạn ghi chú chuẩn bị ngắn (2-3 gạch đầu dòng) cho cuộc họp này."
	default:
		return "Soạn một phản hồi ngắn, phù hợp."
	}
}
