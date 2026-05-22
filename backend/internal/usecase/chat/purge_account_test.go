package chat

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
)

type fakeKeyStorePurge struct {
	deletedFor []string
	deleteErr  error
}

func (f *fakeKeyStorePurge) Read(ctx context.Context, accountUUID string) ([]byte, error) {
	return nil, errors.New("not used")
}
func (f *fakeKeyStorePurge) Write(ctx context.Context, accountUUID string, key []byte) error {
	return nil
}
func (f *fakeKeyStorePurge) Delete(ctx context.Context, accountUUID string) error {
	f.deletedFor = append(f.deletedFor, accountUUID)
	return f.deleteErr
}

// stubChatDirForTest creates a fake chat dir under the production tree, then
// returns a cleanup func. We point at the real adapter.ChatAccountDir path
// so we exercise the same removal logic; a tempdir wouldn't validate that.
func stubChatDirForTest(t *testing.T, accountUUID string) func() {
	t.Helper()
	dir := adapter.ChatAccountDir(accountUUID)
	if err := os.MkdirAll(filepath.Join(dir, "attachments"), 0o700); err != nil {
		t.Fatalf("setup: mkdir: %v", err)
	}
	// Drop a marker file so we can assert removal.
	if err := os.WriteFile(filepath.Join(dir, "chat.db"), []byte("dummy"), 0o600); err != nil {
		t.Fatalf("setup: write: %v", err)
	}
	return func() { _ = os.RemoveAll(dir) }
}

func TestPurgeAccount_RemovesDirAndKey(t *testing.T) {
	uuid := "test-purge-uuid-" + t.Name()
	cleanup := stubChatDirForTest(t, uuid)
	defer cleanup()

	ks := &fakeKeyStorePurge{}
	if err := PurgeAccount(context.Background(), uuid, PurgeOptions{KeyStore: ks}); err != nil {
		t.Fatalf("PurgeAccount: %v", err)
	}

	if _, err := os.Stat(adapter.ChatAccountDir(uuid)); !os.IsNotExist(err) {
		t.Errorf("chat dir still exists after purge")
	}
	if len(ks.deletedFor) != 1 || ks.deletedFor[0] != uuid {
		t.Errorf("key delete = %v, want [%s]", ks.deletedFor, uuid)
	}
}

func TestPurgeAccount_NoExistingData(t *testing.T) {
	// Purging when nothing exists is a no-op success.
	ks := &fakeKeyStorePurge{}
	if err := PurgeAccount(context.Background(), "nonexistent-uuid", PurgeOptions{KeyStore: ks}); err != nil {
		t.Fatalf("PurgeAccount on empty: %v", err)
	}
}

func TestPurgeAccount_RejectsEmptyUUID(t *testing.T) {
	if err := PurgeAccount(context.Background(), "", PurgeOptions{KeyStore: &fakeKeyStorePurge{}}); err == nil {
		t.Fatal("expected error for empty UUID")
	}
}
