package cloudsync

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadSyncStateMissingReturnsZero(t *testing.T) {
	s, err := LoadSyncState(filepath.Join(t.TempDir(), "nope.json"))
	if err != nil {
		t.Fatal(err)
	}
	if s.LastSeq != 0 || s.LastBundleHash != "" {
		t.Fatalf("expected zero state, got %+v", s)
	}
}

func TestSaveLoadSyncStateRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sync.json")
	want := &SyncState{LastSeq: 42, LastBundleHash: "abc"}
	if err := SaveSyncState(path, want); err != nil {
		t.Fatal(err)
	}
	got, err := LoadSyncState(path)
	if err != nil {
		t.Fatal(err)
	}
	if *got != *want {
		t.Fatalf("got %+v want %+v", got, want)
	}
}

func TestLoadSyncStateMalformedReturnsZero(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bad.json")
	_ = os.WriteFile(path, []byte("not json"), 0o600)
	s, err := LoadSyncState(path)
	if err != nil {
		t.Fatal(err)
	}
	if s.LastSeq != 0 {
		t.Fatalf("malformed state should reset to zero, got %+v", s)
	}
}

func TestHashCiphertextStable(t *testing.T) {
	a := HashCiphertext([]byte("hello"))
	b := HashCiphertext([]byte("hello"))
	if a != b {
		t.Fatal("hash should be deterministic")
	}
	if HashCiphertext([]byte("hello")) == HashCiphertext([]byte("world")) {
		t.Fatal("different inputs should hash differently")
	}
}
