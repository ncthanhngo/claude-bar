package lock

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func newTestWaiter(t *testing.T) (*ClaudeRefreshLockWait, string) {
	t.Helper()
	dir := t.TempDir()
	w := NewClaudeRefreshLockWaitAt(dir)
	w.poll = 10 * time.Millisecond
	w.timeout = 300 * time.Millisecond
	return w, filepath.Join(dir, claudeRefreshLockName)
}

func elapsed(f func()) time.Duration {
	start := time.Now()
	f()
	return time.Since(start)
}

func TestRefreshLockWaitNoLockReturnsImmediately(t *testing.T) {
	w, _ := newTestWaiter(t)
	if d := elapsed(func() { w.WaitReleased(context.Background()) }); d > 50*time.Millisecond {
		t.Fatalf("no lock: waited %v", d)
	}
}

func TestRefreshLockWaitStaleLockIgnored(t *testing.T) {
	w, path := newTestWaiter(t)
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-61 * time.Second)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	if d := elapsed(func() { w.WaitReleased(context.Background()) }); d > 50*time.Millisecond {
		t.Fatalf("stale lock: waited %v", d)
	}
}

func TestRefreshLockWaitReturnsOnRelease(t *testing.T) {
	w, path := newTestWaiter(t)
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	go func() {
		time.Sleep(50 * time.Millisecond)
		_ = os.Remove(path)
	}()
	d := elapsed(func() { w.WaitReleased(context.Background()) })
	if d < 40*time.Millisecond || d >= w.timeout {
		t.Fatalf("release: waited %v, want ~50ms", d)
	}
}

func TestRefreshLockWaitGivesUpAtTimeout(t *testing.T) {
	w, path := newTestWaiter(t)
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	d := elapsed(func() { w.WaitReleased(context.Background()) })
	if d < w.timeout || d > w.timeout+200*time.Millisecond {
		t.Fatalf("held lock: waited %v, want ~%v", d, w.timeout)
	}
}

func TestRefreshLockWaitHonoursContext(t *testing.T) {
	w, path := newTestWaiter(t)
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	if d := elapsed(func() { w.WaitReleased(ctx) }); d > 150*time.Millisecond {
		t.Fatalf("cancelled ctx: waited %v", d)
	}
}
