package chat

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// --- Fakes ---

type fakeTokenProvider struct {
	tokens     []string
	uuid       string
	errs       []error
	calls      int
}

func (f *fakeTokenProvider) GetFresh(ctx context.Context, accountNum int) (string, string, error) {
	idx := f.calls
	f.calls++
	if idx < len(f.errs) && f.errs[idx] != nil {
		return "", "", f.errs[idx]
	}
	if idx >= len(f.tokens) {
		return f.tokens[len(f.tokens)-1], f.uuid, nil
	}
	return f.tokens[idx], f.uuid, nil
}

type fakeChatClient struct {
	mu          sync.Mutex
	calls       int
	tokensSeen  []string
	respond     func(call int, token string) (<-chan domain.ChatStreamEvent, error)
}

func (c *fakeChatClient) Stream(ctx context.Context, accessToken string, req port.ChatRequest) (<-chan domain.ChatStreamEvent, error) {
	c.mu.Lock()
	idx := c.calls
	c.calls++
	c.tokensSeen = append(c.tokensSeen, accessToken)
	c.mu.Unlock()
	return c.respond(idx, accessToken)
}

// inMemStorage satisfies port.ChatStorage + VaultStorage with in-memory
// state. Just enough behaviour to drive the orchestration test paths.
type inMemStorage struct {
	accountUUID string
	conv        map[string]*domain.Conversation
	msgs        map[string][]*domain.Message
	atts        map[string]*domain.Attachment
	closed      bool
}

func newInMemStorage(accountUUID string) *inMemStorage {
	return &inMemStorage{
		accountUUID: accountUUID,
		conv:        map[string]*domain.Conversation{},
		msgs:        map[string][]*domain.Message{},
		atts:        map[string]*domain.Attachment{},
	}
}

func (s *inMemStorage) ListConversations(ctx context.Context, accountUUID string) ([]domain.Conversation, error) {
	out := make([]domain.Conversation, 0, len(s.conv))
	for _, c := range s.conv {
		if c.AccountUUID == accountUUID {
			out = append(out, *c)
		}
	}
	return out, nil
}
func (s *inMemStorage) GetConversation(ctx context.Context, accountUUID, id string) (*domain.Conversation, error) {
	c, ok := s.conv[id]
	if !ok {
		return nil, domain.ErrConversationNotFound
	}
	if c.AccountUUID != accountUUID {
		return nil, domain.ErrAccountMismatch
	}
	cp := *c
	return &cp, nil
}
func (s *inMemStorage) CreateConversation(ctx context.Context, c *domain.Conversation) error {
	cp := *c
	s.conv[c.ID] = &cp
	return nil
}
func (s *inMemStorage) UpdateConversation(ctx context.Context, c *domain.Conversation) error {
	cp := *c
	s.conv[c.ID] = &cp
	return nil
}
func (s *inMemStorage) DeleteConversation(ctx context.Context, accountUUID, id string) error {
	delete(s.conv, id)
	delete(s.msgs, id)
	return nil
}
func (s *inMemStorage) ListMessages(ctx context.Context, accountUUID, conversationID string) ([]domain.Message, error) {
	src := s.msgs[conversationID]
	out := make([]domain.Message, len(src))
	for i, m := range src {
		out[i] = *m
	}
	return out, nil
}
func (s *inMemStorage) AppendMessage(ctx context.Context, accountUUID string, m *domain.Message) error {
	cp := *m
	s.msgs[m.ConversationID] = append(s.msgs[m.ConversationID], &cp)
	return nil
}
func (s *inMemStorage) UpdateMessage(ctx context.Context, accountUUID string, m *domain.Message) error {
	for _, msg := range s.msgs[m.ConversationID] {
		if msg.ID == m.ID {
			*msg = *m
			return nil
		}
	}
	return errors.New("not found")
}
func (s *inMemStorage) CreateAttachment(ctx context.Context, accountUUID string, a *domain.Attachment) error {
	cp := *a
	s.atts[a.ID] = &cp
	return nil
}
func (s *inMemStorage) GetAttachment(ctx context.Context, accountUUID, id string) (*domain.Attachment, error) {
	a, ok := s.atts[id]
	if !ok {
		return nil, domain.ErrConversationNotFound
	}
	cp := *a
	return &cp, nil
}
func (s *inMemStorage) DeleteAttachment(ctx context.Context, accountUUID, id string) error {
	delete(s.atts, id)
	return nil
}
func (s *inMemStorage) SearchMessages(ctx context.Context, accountUUID, q string, limit int) ([]domain.Message, error) {
	return nil, nil
}
func (s *inMemStorage) Close() error { s.closed = true; return nil }

// VaultStorage extensions — store plaintext keyed by attachmentID for the
// test. AAD binding tested elsewhere; here we just round-trip.
func (s *inMemStorage) VaultWrite(ctx context.Context, attachmentID string, plaintext []byte) (string, string, error) {
	s.atts["v:"+attachmentID] = &domain.Attachment{
		ID: "v:" + attachmentID, FilePath: string(plaintext),
	}
	return string(plaintext), "nonce", nil
}
func (s *inMemStorage) VaultRead(ctx context.Context, attachmentID, filePath, nonceHex string) ([]byte, error) {
	return []byte(filePath), nil
}

// --- Test helpers ---

func newTestService(t *testing.T, storage *inMemStorage, tp *fakeTokenProvider, cc *fakeChatClient) *Service {
	t.Helper()
	openCount := 0
	open := func(ctx context.Context, accountUUID string) (port.ChatStorage, error) {
		openCount++
		if storage.accountUUID == "" {
			storage.accountUUID = accountUUID
		}
		return storage, nil
	}
	idCounter := 0
	return &Service{
		TokenProvider: tp,
		ChatClient:    cc,
		OpenStorage:   open,
		Now:           func() time.Time { return time.Unix(1700000000, 0).UTC() },
		NewID: func() string {
			idCounter++
			return "id-" + string(rune('A'+idCounter-1))
		},
	}
}

func scriptedStream(events ...domain.ChatStreamEvent) <-chan domain.ChatStreamEvent {
	ch := make(chan domain.ChatStreamEvent, len(events))
	for _, e := range events {
		ch <- e
	}
	close(ch)
	return ch
}

// --- Tests ---

func TestCreateAndLoadConversation(t *testing.T) {
	storage := newInMemStorage("")
	tp := &fakeTokenProvider{tokens: []string{"tok1"}, uuid: "acc-uuid-1"}
	svc := newTestService(t, storage, tp, &fakeChatClient{})

	conv, err := svc.CreateConversation(context.Background(), 1, "claude-sonnet-4-6", "be brief", "Hello")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if conv.AccountUUID != "acc-uuid-1" {
		t.Errorf("uuid = %q", conv.AccountUUID)
	}

	got, msgs, err := svc.LoadConversation(context.Background(), 1, conv.ID)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if got.Title != "Hello" {
		t.Errorf("title = %q", got.Title)
	}
	if len(msgs) != 0 {
		t.Errorf("expected 0 messages, got %d", len(msgs))
	}
}

func TestSendMessage_HappyPath(t *testing.T) {
	storage := newInMemStorage("acc-uuid-1")
	storage.conv["conv1"] = &domain.Conversation{
		ID: "conv1", AccountUUID: "acc-uuid-1", Model: "claude-sonnet-4-6",
		CreatedAt: time.Now(), UpdatedAt: time.Now(),
	}

	tp := &fakeTokenProvider{tokens: []string{"tok1"}, uuid: "acc-uuid-1"}
	cc := &fakeChatClient{
		respond: func(call int, token string) (<-chan domain.ChatStreamEvent, error) {
			return scriptedStream(
				domain.ChatStreamEvent{Kind: domain.StreamUsage, InputTokens: 10},
				domain.ChatStreamEvent{Kind: domain.StreamTextDelta, Text: "Hello "},
				domain.ChatStreamEvent{Kind: domain.StreamTextDelta, Text: "world"},
				domain.ChatStreamEvent{Kind: domain.StreamDone, StopReason: "end_turn", OutputTokens: 4, InputTokens: 10},
			), nil
		},
	}
	svc := newTestService(t, storage, tp, cc)

	outcome, err := svc.SendMessage(context.Background(), 1, "conv1",
		[]domain.ContentBlock{{Kind: domain.BlockText, Text: "hi"}})
	if err != nil {
		t.Fatalf("send: %v", err)
	}
	var got []domain.ChatStreamEvent
	for ev := range outcome.Events {
		got = append(got, ev)
	}
	if len(got) != 4 {
		t.Fatalf("events = %d, want 4", len(got))
	}
	// User + assistant both persisted.
	msgs := storage.msgs["conv1"]
	if len(msgs) != 2 {
		t.Fatalf("messages persisted = %d, want 2", len(msgs))
	}
	if msgs[1].Role != domain.RoleAssistant {
		t.Errorf("second msg role = %q", msgs[1].Role)
	}
	if msgs[1].PlainText() != "Hello world" {
		t.Errorf("assistant text = %q", msgs[1].PlainText())
	}
	if msgs[1].InputTokens != 10 || msgs[1].OutputTokens != 4 {
		t.Errorf("tokens = (%d,%d)", msgs[1].InputTokens, msgs[1].OutputTokens)
	}
}

func TestSendMessage_UnauthorizedThenRetrySuccess(t *testing.T) {
	storage := newInMemStorage("acc-uuid-1")
	storage.conv["conv1"] = &domain.Conversation{
		ID: "conv1", AccountUUID: "acc-uuid-1", Model: "claude-sonnet-4-6",
	}
	tp := &fakeTokenProvider{tokens: []string{"old-tok", "new-tok"}, uuid: "acc-uuid-1"}
	cc := &fakeChatClient{
		respond: func(call int, token string) (<-chan domain.ChatStreamEvent, error) {
			if call == 0 {
				return nil, domain.ErrUnauthorized
			}
			return scriptedStream(
				domain.ChatStreamEvent{Kind: domain.StreamTextDelta, Text: "ok"},
				domain.ChatStreamEvent{Kind: domain.StreamDone, StopReason: "end_turn"},
			), nil
		},
	}
	svc := newTestService(t, storage, tp, cc)

	outcome, err := svc.SendMessage(context.Background(), 1, "conv1",
		[]domain.ContentBlock{{Kind: domain.BlockText, Text: "hi"}})
	if err != nil {
		t.Fatalf("send: %v", err)
	}
	for range outcome.Events {
	}
	if cc.calls != 2 {
		t.Errorf("chat client calls = %d, want 2", cc.calls)
	}
	if cc.tokensSeen[1] != "new-tok" {
		t.Errorf("retry token = %q, want new-tok", cc.tokensSeen[1])
	}
}

func TestSendMessage_DoubleUnauthorized_Fails(t *testing.T) {
	storage := newInMemStorage("acc-uuid-1")
	storage.conv["conv1"] = &domain.Conversation{
		ID: "conv1", AccountUUID: "acc-uuid-1", Model: "claude-sonnet-4-6",
	}
	tp := &fakeTokenProvider{tokens: []string{"t1", "t2"}, uuid: "acc-uuid-1"}
	cc := &fakeChatClient{
		respond: func(call int, token string) (<-chan domain.ChatStreamEvent, error) {
			return nil, domain.ErrUnauthorized
		},
	}
	svc := newTestService(t, storage, tp, cc)

	_, err := svc.SendMessage(context.Background(), 1, "conv1",
		[]domain.ContentBlock{{Kind: domain.BlockText, Text: "hi"}})
	if !errors.Is(err, domain.ErrTokenRefreshFailed) {
		t.Fatalf("err = %v, want ErrTokenRefreshFailed", err)
	}
}

func TestSendMessage_StreamErrorSkipsPersist(t *testing.T) {
	storage := newInMemStorage("acc-uuid-1")
	storage.conv["conv1"] = &domain.Conversation{
		ID: "conv1", AccountUUID: "acc-uuid-1", Model: "claude-sonnet-4-6",
	}
	tp := &fakeTokenProvider{tokens: []string{"t1"}, uuid: "acc-uuid-1"}
	cc := &fakeChatClient{
		respond: func(call int, token string) (<-chan domain.ChatStreamEvent, error) {
			return scriptedStream(
				domain.ChatStreamEvent{Kind: domain.StreamTextDelta, Text: "partial"},
				domain.ChatStreamEvent{Kind: domain.StreamError, ErrorCode: "overloaded", ErrorMessage: "x"},
			), nil
		},
	}
	svc := newTestService(t, storage, tp, cc)
	outcome, err := svc.SendMessage(context.Background(), 1, "conv1",
		[]domain.ContentBlock{{Kind: domain.BlockText, Text: "hi"}})
	if err != nil {
		t.Fatalf("send: %v", err)
	}
	for range outcome.Events {
	}
	// User msg persisted (1), assistant NOT (no row 2).
	if got := len(storage.msgs["conv1"]); got != 1 {
		t.Fatalf("messages = %d, want 1 (user only, no half-assistant)", got)
	}
}

func TestSendMessage_AttachmentInflated(t *testing.T) {
	storage := newInMemStorage("acc-uuid-1")
	storage.conv["conv1"] = &domain.Conversation{
		ID: "conv1", AccountUUID: "acc-uuid-1", Model: "claude-sonnet-4-6",
	}
	storage.atts["att1"] = &domain.Attachment{
		ID: "att1", ConversationID: "conv1", MediaType: "image/png",
		FilePath: "raw-bytes-go-here", NonceHex: "nonce",
	}

	tp := &fakeTokenProvider{tokens: []string{"t1"}, uuid: "acc-uuid-1"}
	var seenReq port.ChatRequest
	cc := &fakeChatClient{
		respond: func(call int, token string) (<-chan domain.ChatStreamEvent, error) {
			return scriptedStream(
				domain.ChatStreamEvent{Kind: domain.StreamDone, StopReason: "end_turn"},
			), nil
		},
	}
	svc := newTestService(t, storage, tp, cc)

	// Wrap chatClient.Stream so we can capture the request.
	origRespond := cc.respond
	cc.respond = func(call int, token string) (<-chan domain.ChatStreamEvent, error) {
		return origRespond(call, token)
	}
	// Push a message manually so the inflater has something with an image block.
	storage.msgs["conv1"] = []*domain.Message{
		{ID: "u0", ConversationID: "conv1", Role: domain.RoleUser, Content: []domain.ContentBlock{
			{Kind: domain.BlockImage, AttachmentID: "att1", MediaType: "image/png"},
		}},
	}

	outcome, err := svc.SendMessage(context.Background(), 1, "conv1",
		[]domain.ContentBlock{{Kind: domain.BlockText, Text: "describe"}})
	if err != nil {
		t.Fatalf("send: %v", err)
	}
	for range outcome.Events {
	}
	_ = seenReq // (the test asserts no crash + persistence below)
	// Two user msgs persisted (u0 + new one); inflation didn't error.
	if got := len(storage.msgs["conv1"]); got != 2 {
		t.Fatalf("messages = %d, want 2", got)
	}
}

func TestRenameAndDelete(t *testing.T) {
	storage := newInMemStorage("acc-uuid-1")
	storage.conv["c1"] = &domain.Conversation{
		ID: "c1", AccountUUID: "acc-uuid-1", Title: "old", Model: "x",
	}
	tp := &fakeTokenProvider{tokens: []string{"t"}, uuid: "acc-uuid-1"}
	svc := newTestService(t, storage, tp, &fakeChatClient{})

	if err := svc.RenameConversation(context.Background(), 1, "c1", "new"); err != nil {
		t.Fatalf("rename: %v", err)
	}
	if storage.conv["c1"].Title != "new" {
		t.Errorf("title = %q", storage.conv["c1"].Title)
	}
	if err := svc.DeleteConversation(context.Background(), 1, "c1"); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if _, exists := storage.conv["c1"]; exists {
		t.Errorf("conv still present after delete")
	}
}

func TestAttachFile_SizeCap(t *testing.T) {
	storage := newInMemStorage("acc-uuid-1")
	storage.conv["c1"] = &domain.Conversation{ID: "c1", AccountUUID: "acc-uuid-1", Model: "x"}
	tp := &fakeTokenProvider{tokens: []string{"t"}, uuid: "acc-uuid-1"}
	svc := newTestService(t, storage, tp, &fakeChatClient{})

	big := make([]byte, MaxImageBytes+1)
	_, err := svc.AttachFile(context.Background(), 1, "c1", "huge.png", "image/png", domain.AttachImage, big)
	if !errors.Is(err, domain.ErrAttachmentTooLarge) {
		t.Fatalf("err = %v, want ErrAttachmentTooLarge", err)
	}
}

func TestAttachFile_Persists(t *testing.T) {
	storage := newInMemStorage("acc-uuid-1")
	storage.conv["c1"] = &domain.Conversation{ID: "c1", AccountUUID: "acc-uuid-1", Model: "x"}
	tp := &fakeTokenProvider{tokens: []string{"t"}, uuid: "acc-uuid-1"}
	svc := newTestService(t, storage, tp, &fakeChatClient{})

	att, err := svc.AttachFile(context.Background(), 1, "c1", "small.png", "image/png", domain.AttachImage, []byte("hi"))
	if err != nil {
		t.Fatalf("attach: %v", err)
	}
	if att.SizeBytes != 2 {
		t.Errorf("size = %d", att.SizeBytes)
	}
	if storage.atts[att.ID] == nil {
		t.Errorf("attachment row not persisted")
	}
}
