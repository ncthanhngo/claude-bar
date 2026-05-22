package chatstorage

import (
	"bytes"
	"context"
	"crypto/rand"
	"os"
	"testing"
)

func newTestVault(t *testing.T) (*AttachmentVault, string) {
	t.Helper()
	dir := t.TempDir()
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		t.Fatalf("rand key: %v", err)
	}
	v, err := NewAttachmentVault(key, "acc-uuid-test", dir)
	if err != nil {
		t.Fatalf("NewAttachmentVault: %v", err)
	}
	return v, dir
}

func TestVault_RoundTrip(t *testing.T) {
	v, _ := newTestVault(t)
	plaintext := make([]byte, 1<<20) // 1 MB
	_, _ = rand.Read(plaintext)

	path, nonce, err := v.Write(context.Background(), "att-1", plaintext)
	if err != nil {
		t.Fatalf("Write: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("written file not present: %v", err)
	}

	got, err := v.Read(context.Background(), "att-1", path, nonce)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if !bytes.Equal(got, plaintext) {
		t.Fatal("round-trip mismatch")
	}
}

func TestVault_TamperDetection(t *testing.T) {
	v, _ := newTestVault(t)
	plaintext := []byte("sensitive content")

	path, nonce, err := v.Write(context.Background(), "att-2", plaintext)
	if err != nil {
		t.Fatalf("Write: %v", err)
	}

	// Flip one byte in the middle of the ciphertext.
	ct, _ := os.ReadFile(path)
	ct[len(ct)/2] ^= 0x01
	if err := os.WriteFile(path, ct, 0o600); err != nil {
		t.Fatalf("rewrite: %v", err)
	}

	if _, err := v.Read(context.Background(), "att-2", path, nonce); err == nil {
		t.Fatal("expected AEAD open to fail after tamper, got nil")
	}
}

func TestVault_WrongAttachmentID(t *testing.T) {
	v, _ := newTestVault(t)
	pt := []byte("hello")
	path, nonce, err := v.Write(context.Background(), "att-A", pt)
	if err != nil {
		t.Fatalf("Write: %v", err)
	}
	// AAD binds to the attachment ID — reading with a different ID must fail.
	if _, err := v.Read(context.Background(), "att-B", path, nonce); err == nil {
		t.Fatal("expected AEAD open to fail with wrong attachmentID")
	}
}

func TestVault_FileSizeOverhead(t *testing.T) {
	v, _ := newTestVault(t)
	pt := make([]byte, 1024)
	_, _ = rand.Read(pt)
	path, _, err := v.Write(context.Background(), "att-3", pt)
	if err != nil {
		t.Fatalf("Write: %v", err)
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	// XChaCha20-Poly1305 appends 16 bytes of tag — file size = plaintext + 16.
	if st.Size() != int64(len(pt)+16) {
		t.Fatalf("file size = %d, want %d", st.Size(), len(pt)+16)
	}
}
