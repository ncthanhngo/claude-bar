package chat

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// DiagnosticsReport is what the widget Settings → Diagnostics → Chat panel
// renders. Cheap to compute — pure file-system stat + a conversation count.
type DiagnosticsReport struct {
	AccountUUID       string `json:"account_uuid"`
	ConversationCount int    `json:"conversation_count"`
	MessageCount      int    `json:"message_count"`
	AttachmentCount   int    `json:"attachment_count"`
	DBSizeBytes       int64  `json:"db_size_bytes"`
	AttachmentsBytes  int64  `json:"attachments_bytes"`
	StorageDir        string `json:"storage_dir"`
}

// CollectDiagnostics returns counts + disk usage for the active account's
// chat data. Safe to call when no chat dir exists (returns zeros). Doesn't
// open the DB if it's there — uses the storage layer for counts, file
// stat for sizes.
func (s *Service) CollectDiagnostics(ctx context.Context, accountNum int) (*DiagnosticsReport, error) {
	_, accountUUID, storage, err := s.openForAccount(ctx, accountNum)
	if err != nil {
		return nil, err
	}
	defer storage.Close()

	report := &DiagnosticsReport{
		AccountUUID: accountUUID,
		StorageDir:  adapter.ChatAccountDir(accountUUID),
	}

	convs, err := storage.ListConversations(ctx, accountUUID)
	if err == nil {
		report.ConversationCount = len(convs)
		for _, c := range convs {
			if msgs, err := storage.ListMessages(ctx, accountUUID, c.ID); err == nil {
				report.MessageCount += len(msgs)
				for _, m := range msgs {
					for _, b := range m.Content {
						if b.AttachmentID != "" {
							report.AttachmentCount++
						}
					}
				}
			}
		}
	}

	dbStat, err := os.Stat(adapter.ChatDBFile(accountUUID))
	if err == nil {
		report.DBSizeBytes = dbStat.Size()
	}
	report.AttachmentsBytes = directorySize(adapter.ChatAttachmentDir(accountUUID))
	return report, nil
}

// directorySize walks a tree and sums file sizes. Returns 0 on any error.
func directorySize(root string) int64 {
	var total int64
	_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || info == nil || info.IsDir() {
			return nil
		}
		total += info.Size()
		return nil
	})
	return total
}

// TestPrompt sends a trivial "ping" prompt to confirm the chat pipeline is
// alive (OAuth fresh, adapter reachable, stream working). Used by
// Settings → Diagnostics → "Test chat". Returns latency to first event in
// milliseconds. Creates + deletes a throwaway conversation if the account
// has none yet, so a successful test doesn't pollute the rail.
func (s *Service) TestPrompt(ctx context.Context, accountNum int) (latencyMs int64, err error) {
	convs, err := s.ListConversations(ctx, accountNum)
	if err != nil {
		return 0, fmt.Errorf("list: %w", err)
	}
	var convID string
	var cleanup bool
	if len(convs) > 0 {
		convID = convs[0].ID
	} else {
		conv, err := s.CreateConversation(ctx, accountNum,
			"claude-haiku-4-5-20251001", "", "diag-test")
		if err != nil {
			return 0, fmt.Errorf("create test conv: %w", err)
		}
		convID = conv.ID
		cleanup = true
	}

	t0 := time.Now()
	outcome, err := s.SendMessage(ctx, accountNum, convID,
		[]domain.ContentBlock{{Kind: domain.BlockText, Text: "ping"}})
	if err != nil {
		return 0, err
	}
	// Wait for the first non-usage event (text_delta or done) to land —
	// that's our latency measurement.
	var firstLatency int64
	for ev := range outcome.Events {
		if firstLatency == 0 && (ev.Kind == domain.StreamTextDelta || ev.Kind == domain.StreamDone) {
			firstLatency = time.Since(t0).Milliseconds()
		}
	}
	if cleanup {
		_ = s.DeleteConversation(ctx, accountNum, convID)
	}
	if firstLatency == 0 {
		return 0, fmt.Errorf("no events received — pipeline broken")
	}
	return firstLatency, nil
}
