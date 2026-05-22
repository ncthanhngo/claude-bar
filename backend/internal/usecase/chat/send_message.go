package chat

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// SendOutcome is the channel-side return of SendMessage. Callers MUST
// range over Events until close. AssistantMessageID resolves once the
// stream completes successfully (or stays "" on cancel / error).
type SendOutcome struct {
	UserMessageID string
	Events        <-chan domain.ChatStreamEvent
}

// SendMessage is the core chat orchestration. Steps:
//  1. Get a fresh OAuth token + open per-account storage.
//  2. Validate conversation belongs to this account.
//  3. Persist the user message FIRST (so a crash after this point still
//     leaves the user's input safe).
//  4. Load full history, inflate attachment bytes from the vault.
//  5. Stream from Anthropic. Retry exactly once on a fresh 401 (token
//     just rotated mid-call).
//  6. As tokens come back, forward to caller AND accumulate into a
//     buffer. On `done`, persist assistant message + bump conv.updated_at.
//
// The returned channel closes when the stream finishes (success or error).
// Cancellation: ctx propagates into adapter.Stream which closes the body;
// the worker goroutine exits, channel closes, storage closes — assistant
// message is NOT persisted on cancel.
func (s *Service) SendMessage(
	ctx context.Context,
	accountNum int,
	conversationID string,
	userBlocks []domain.ContentBlock,
) (*SendOutcome, error) {
	accessToken, accountUUID, storage, err := s.openForAccount(ctx, accountNum)
	if err != nil {
		return nil, err
	}
	cleanupOnEarlyError := func() { _ = storage.Close() }

	conv, err := storage.GetConversation(ctx, accountUUID, conversationID)
	if err != nil {
		cleanupOnEarlyError()
		return nil, err
	}
	history, err := storage.ListMessages(ctx, accountUUID, conversationID)
	if err != nil {
		cleanupOnEarlyError()
		return nil, err
	}

	now := s.Now()
	userMsg := &domain.Message{
		ID:             s.NewID(),
		ConversationID: conversationID,
		Role:           domain.RoleUser,
		Content:        userBlocks,
		CreatedAt:      now,
	}
	if err := storage.AppendMessage(ctx, accountUUID, userMsg); err != nil {
		cleanupOnEarlyError()
		return nil, fmt.Errorf("persist user message: %w", err)
	}
	history = append(history, *userMsg)

	vault, ok := storage.(VaultStorage)
	if !ok {
		cleanupOnEarlyError()
		return nil, errors.New("chat: storage does not expose attachment vault")
	}
	inflated, err := inflateAttachments(ctx, accountUUID, vault, history)
	if err != nil {
		cleanupOnEarlyError()
		return nil, err
	}

	req := port.ChatRequest{
		Model:        conv.Model,
		SystemPrompt: conv.SystemPrompt,
		Messages:     inflated,
		MaxTokens:    4096,
		Stream:       true,
	}

	upstream, err := s.streamWithOneRetry(ctx, accountNum, accessToken, req)
	if err != nil {
		cleanupOnEarlyError()
		return nil, err
	}

	out := make(chan domain.ChatStreamEvent, 16)
	go s.consumeStream(consumeStreamArgs{
		Ctx:            ctx,
		AccountUUID:    accountUUID,
		Conversation:   conv,
		ConversationID: conversationID,
		Storage:        storage,
		Upstream:       upstream,
		Out:            out,
	})
	return &SendOutcome{UserMessageID: userMsg.ID, Events: out}, nil
}

// streamWithOneRetry handles the "token rotated mid-call" race by asking
// the token provider for a fresh token exactly once when the adapter
// returns ErrUnauthorized. A second 401 surfaces as ErrTokenRefreshFailed.
func (s *Service) streamWithOneRetry(
	ctx context.Context,
	accountNum int,
	accessToken string,
	req port.ChatRequest,
) (<-chan domain.ChatStreamEvent, error) {
	ch, err := s.ChatClient.Stream(ctx, accessToken, req)
	if !errors.Is(err, domain.ErrUnauthorized) {
		return ch, err
	}
	fresh, _, err := s.TokenProvider.GetFresh(ctx, accountNum)
	if err != nil {
		return nil, err
	}
	ch, err = s.ChatClient.Stream(ctx, fresh, req)
	if errors.Is(err, domain.ErrUnauthorized) {
		return nil, domain.ErrTokenRefreshFailed
	}
	return ch, err
}

type consumeStreamArgs struct {
	Ctx            context.Context
	AccountUUID    string
	Conversation   *domain.Conversation
	ConversationID string
	Storage        port.ChatStorage
	Upstream       <-chan domain.ChatStreamEvent
	Out            chan<- domain.ChatStreamEvent
}

// consumeStream forwards upstream events while accumulating the assistant
// text. On a clean Done it persists the assistant message + bumps
// conv.updated_at; on Error it forwards the event and skips persistence;
// on ctx cancel the goroutine exits without persisting.
func (s *Service) consumeStream(a consumeStreamArgs) {
	defer close(a.Out)
	defer func() { _ = a.Storage.Close() }()

	var (
		textBuf      strings.Builder
		inputTokens  int
		outputTokens int
		stopReason   string
		gotDone      bool
		gotError     bool
	)

	for ev := range a.Upstream {
		switch ev.Kind {
		case domain.StreamTextDelta:
			textBuf.WriteString(ev.Text)
		case domain.StreamUsage:
			inputTokens = ev.InputTokens
			if ev.OutputTokens > 0 {
				outputTokens = ev.OutputTokens
			}
		case domain.StreamDone:
			gotDone = true
			stopReason = ev.StopReason
			if ev.InputTokens > 0 {
				inputTokens = ev.InputTokens
			}
			if ev.OutputTokens > 0 {
				outputTokens = ev.OutputTokens
			}
		case domain.StreamError:
			gotError = true
		}
		select {
		case a.Out <- ev:
		case <-a.Ctx.Done():
			return
		}
	}

	if !gotDone || gotError || textBuf.Len() == 0 {
		return
	}

	persistCtx := context.Background()
	asst := &domain.Message{
		ID:             s.NewID(),
		ConversationID: a.ConversationID,
		Role:           domain.RoleAssistant,
		Content:        []domain.ContentBlock{{Kind: domain.BlockText, Text: textBuf.String()}},
		InputTokens:    inputTokens,
		OutputTokens:   outputTokens,
		StopReason:     stopReason,
		CreatedAt:      s.Now(),
	}
	if err := a.Storage.AppendMessage(persistCtx, a.AccountUUID, asst); err != nil {
		// Stream already closed for the caller. Best we can do is log.
		// The user msg is already saved so the conversation isn't broken;
		// resending will replay the request.
		// (Caller-visible error path stays inside the channel.)
		return
	}
	a.Conversation.UpdatedAt = s.Now()
	_ = a.Storage.UpdateConversation(persistCtx, a.Conversation)
}
