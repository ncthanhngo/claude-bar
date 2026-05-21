package cloudsync

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestWriteBundleAtomicCreatesAndOverwrites(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "bundle.enc")

	if err := WriteBundleAtomic(dest, []byte("v1")); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(dest)
	if !bytes.Equal(got, []byte("v1")) {
		t.Fatalf("v1 mismatch: %q", got)
	}
	if err := WriteBundleAtomic(dest, []byte("v2")); err != nil {
		t.Fatal(err)
	}
	got, _ = os.ReadFile(dest)
	if !bytes.Equal(got, []byte("v2")) {
		t.Fatalf("v2 mismatch: %q", got)
	}

	// Tmp files in the same dir should be cleaned up.
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if e.Name() != "bundle.enc" {
			t.Fatalf("unexpected leftover file: %s", e.Name())
		}
	}
}

func TestWriteBundleAtomicHas0o600Perm(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "bundle.enc")
	if err := WriteBundleAtomic(dest, []byte("x")); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(dest)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("expected 0o600, got %o", perm)
	}
}

func TestRotateBackupsShiftsExistingSlots(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "bundle.enc")

	// Seed three pushes: each push writes new content and rotates first.
	push := func(content string) {
		t.Helper()
		if err := RotateBackups(dest); err != nil {
			t.Fatal(err)
		}
		if err := WriteBundleAtomic(dest, []byte(content)); err != nil {
			t.Fatal(err)
		}
	}
	push("gen1") // dest=gen1
	push("gen2") // dest=gen2, .1=gen1
	push("gen3") // dest=gen3, .1=gen2, .2=gen1

	read := func(path string) string {
		t.Helper()
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	if got := read(dest); got != "gen3" {
		t.Fatalf("dest = %q, want gen3", got)
	}
	if got := read(dest + ".1"); got != "gen2" {
		t.Fatalf(".1 = %q, want gen2", got)
	}
	if got := read(dest + ".2"); got != "gen1" {
		t.Fatalf(".2 = %q, want gen1", got)
	}
}

func TestRotateBackupsDropsOldestPastLimit(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "bundle.enc")
	for i := 0; i < BackupCount+3; i++ {
		if err := RotateBackups(dest); err != nil {
			t.Fatal(err)
		}
		if err := WriteBundleAtomic(dest, []byte{byte(i)}); err != nil {
			t.Fatal(err)
		}
	}
	// Only dest + .1..BackupCount should exist.
	beyond := dest + "." + itoa(BackupCount+1)
	if _, err := os.Stat(beyond); !os.IsNotExist(err) {
		t.Fatalf("expected %s to not exist, err=%v", beyond, err)
	}
}

func TestBackupPathsReturnsOnlyExistingSlots(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "bundle.enc")
	_ = os.WriteFile(dest+".1", []byte("a"), 0o600)
	_ = os.WriteFile(dest+".3", []byte("c"), 0o600)
	paths := BackupPaths(dest)
	if len(paths) != 2 {
		t.Fatalf("want 2, got %d: %v", len(paths), paths)
	}
}

// itoa avoids the strconv import for one tiny test case.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
