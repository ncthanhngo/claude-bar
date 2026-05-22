package chatstorage

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// fakeKeyStore is an in-memory ChatDBKeyStore for tests — no Keychain access.
type fakeKeyStore struct {
	store map[string][]byte
}

func newFakeKeyStore() *fakeKeyStore { return &fakeKeyStore{store: map[string][]byte{}} }

func (f *fakeKeyStore) Read(ctx context.Context, accountUUID string) ([]byte, error) {
	v, ok := f.store[accountUUID]
	if !ok {
		return nil, port.ErrKeyNotFound
	}
	return v, nil
}
func (f *fakeKeyStore) Write(ctx context.Context, accountUUID string, key []byte) error {
	f.store[accountUUID] = key
	return nil
}
func (f *fakeKeyStore) Delete(ctx context.Context, accountUUID string) error {
	delete(f.store, accountUUID)
	return nil
}

func openTempStorage(t *testing.T, accountUUID string, ks port.ChatDBKeyStore) (*Storage, string) {
	t.Helper()
	root := t.TempDir()
	dbPath := filepath.Join(root, "chat.db")
	attachDir := filepath.Join(root, "attachments")
	s, err := Open(context.Background(), accountUUID, ks, dbPath, attachDir)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	return s, root
}

func TestStorage_OpenCreatesDB(t *testing.T) {
	ks := newFakeKeyStore()
	s, root := openTempStorage(t, "acc-1", ks)
	defer s.Close()

	if _, err := os.Stat(filepath.Join(root, "chat.db")); err != nil {
		t.Fatalf("chat.db not created: %v", err)
	}
	if len(ks.store["acc-1"]) != MasterKeySize {
		t.Fatalf("master key not stored")
	}
}

func TestStorage_WrongKeyFailsOpen(t *testing.T) {
	ks := newFakeKeyStore()
	s, root := openTempStorage(t, "acc-1", ks)
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// Mutate the stored key to a different random one — re-open should fail
	// because SQLCipher won't accept the new dbKey.
	wrong := make([]byte, MasterKeySize)
	_, _ = rand.Read(wrong)
	ks.store["acc-1"] = wrong

	dbPath := filepath.Join(root, "chat.db")
	attachDir := filepath.Join(root, "attachments")
	_, err := Open(context.Background(), "acc-1", ks, dbPath, attachDir)
	if err == nil {
		t.Fatal("expected Open with wrong key to fail, got nil")
	}
}

func TestStorage_ConversationCRUD(t *testing.T) {
	ks := newFakeKeyStore()
	s, _ := openTempStorage(t, "acc-1", ks)
	defer s.Close()
	ctx := context.Background()

	c := &domain.Conversation{
		ID: "c1", AccountUUID: "acc-1",
		Title: "first", Model: "claude-sonnet-4-6",
		CreatedAt: time.Now().UTC(), UpdatedAt: time.Now().UTC(),
	}
	if err := s.CreateConversation(ctx, c); err != nil {
		t.Fatalf("Create: %v", err)
	}
	got, err := s.GetConversation(ctx, "acc-1", "c1")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.Title != "first" {
		t.Errorf("Title = %q", got.Title)
	}

	c.Title = "renamed"
	c.UpdatedAt = time.Now().UTC()
	if err := s.UpdateConversation(ctx, c); err != nil {
		t.Fatalf("Update: %v", err)
	}
	got2, _ := s.GetConversation(ctx, "acc-1", "c1")
	if got2.Title != "renamed" {
		t.Errorf("after update Title = %q", got2.Title)
	}

	list, err := s.ListConversations(ctx, "acc-1")
	if err != nil || len(list) != 1 {
		t.Fatalf("List len = %d err = %v", len(list), err)
	}

	if err := s.DeleteConversation(ctx, "acc-1", "c1"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	_, err = s.GetConversation(ctx, "acc-1", "c1")
	if !errors.Is(err, domain.ErrConversationNotFound) {
		t.Fatalf("post-delete Get err = %v, want ErrConversationNotFound", err)
	}
}

func TestStorage_AccountMismatch(t *testing.T) {
	ks := newFakeKeyStore()
	s, _ := openTempStorage(t, "acc-1", ks)
	defer s.Close()
	ctx := context.Background()

	c := &domain.Conversation{ID: "c1", AccountUUID: "acc-1", Model: "x", CreatedAt: time.Now(), UpdatedAt: time.Now()}
	_ = s.CreateConversation(ctx, c)

	if _, err := s.GetConversation(ctx, "acc-2", "c1"); !errors.Is(err, domain.ErrAccountMismatch) {
		t.Errorf("cross-account get err = %v, want ErrAccountMismatch", err)
	}
}

func TestStorage_MessagesAndSearch(t *testing.T) {
	ks := newFakeKeyStore()
	s, _ := openTempStorage(t, "acc-1", ks)
	defer s.Close()
	ctx := context.Background()

	_ = s.CreateConversation(ctx, &domain.Conversation{
		ID: "c1", AccountUUID: "acc-1", Model: "claude-sonnet-4-6",
		CreatedAt: time.Now(), UpdatedAt: time.Now(),
	})

	now := time.Now().UTC()
	msgs := []*domain.Message{
		{ID: "m1", ConversationID: "c1", Role: domain.RoleUser, CreatedAt: now,
			Content: []domain.ContentBlock{{Kind: domain.BlockText, Text: "hello claude"}}},
		{ID: "m2", ConversationID: "c1", Role: domain.RoleAssistant, CreatedAt: now.Add(time.Second),
			Content: []domain.ContentBlock{{Kind: domain.BlockText, Text: "hi there, how can I help?"}}},
		{ID: "m3", ConversationID: "c1", Role: domain.RoleUser, CreatedAt: now.Add(2 * time.Second),
			Content: []domain.ContentBlock{{Kind: domain.BlockText, Text: "test FTS search"}}},
	}
	for _, m := range msgs {
		if err := s.AppendMessage(ctx, "acc-1", m); err != nil {
			t.Fatalf("AppendMessage %s: %v", m.ID, err)
		}
	}

	listed, err := s.ListMessages(ctx, "acc-1", "c1")
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(listed) != 3 {
		t.Fatalf("list len = %d", len(listed))
	}

	found, err := s.SearchMessages(ctx, "acc-1", "claude", 10)
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(found) != 1 || found[0].ID != "m1" {
		t.Fatalf("Search results = %+v", found)
	}
}

func TestStorage_AttachmentRoundTrip(t *testing.T) {
	ks := newFakeKeyStore()
	s, root := openTempStorage(t, "acc-1", ks)
	defer s.Close()
	ctx := context.Background()

	_ = s.CreateConversation(ctx, &domain.Conversation{
		ID: "c1", AccountUUID: "acc-1", Model: "x",
		CreatedAt: time.Now(), UpdatedAt: time.Now(),
	})

	plaintext := []byte("the contents of a small PDF")
	path, nonce, err := s.Vault().Write(ctx, "att-1", plaintext)
	if err != nil {
		t.Fatalf("vault.Write: %v", err)
	}
	att := &domain.Attachment{
		ID: "att-1", ConversationID: "c1", Kind: domain.AttachPDF,
		Filename: "spec.pdf", MediaType: "application/pdf",
		SizeBytes: int64(len(plaintext)), FilePath: path, NonceHex: nonce,
		CreatedAt: time.Now().UTC(),
	}
	if err := s.CreateAttachment(ctx, "acc-1", att); err != nil {
		t.Fatalf("CreateAttachment: %v", err)
	}

	got, err := s.GetAttachment(ctx, "acc-1", "att-1")
	if err != nil {
		t.Fatalf("GetAttachment: %v", err)
	}
	pt, err := s.Vault().Read(ctx, got.ID, got.FilePath, got.NonceHex)
	if err != nil {
		t.Fatalf("vault.Read: %v", err)
	}
	if !bytes.Equal(pt, plaintext) {
		t.Fatal("attachment round-trip mismatch")
	}
	// File is in the expected per-account dir under our temp root.
	if filepath.Dir(path) != filepath.Join(root, "attachments") {
		t.Errorf("attachment lives in %q, want under %q", path, root)
	}
}

func TestStorage_PersistsAcrossReopen(t *testing.T) {
	ks := newFakeKeyStore()
	s, root := openTempStorage(t, "acc-1", ks)
	ctx := context.Background()
	now := time.Now().UTC()
	_ = s.CreateConversation(ctx, &domain.Conversation{
		ID: "c1", AccountUUID: "acc-1", Title: "stays", Model: "claude-sonnet-4-6",
		CreatedAt: now, UpdatedAt: now,
	})
	if err := s.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	s2, err := Open(ctx, "acc-1", ks, filepath.Join(root, "chat.db"), filepath.Join(root, "attachments"))
	if err != nil {
		t.Fatalf("re-Open: %v", err)
	}
	defer s2.Close()

	c, err := s2.GetConversation(ctx, "acc-1", "c1")
	if err != nil {
		t.Fatalf("re-Get: %v", err)
	}
	if c.Title != "stays" {
		t.Errorf("Title = %q after reopen", c.Title)
	}
}
