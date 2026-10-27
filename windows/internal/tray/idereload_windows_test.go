//go:build windows

package tray

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/windows"
)

func TestIDESessionsPicksOnlyLiveIDESessions(t *testing.T) {
	home := t.TempDir()
	t.Setenv("USERPROFILE", home)
	dir := filepath.Join(home, ".claude", "sessions")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}

	var created, exited, kernel, user windows.Filetime
	if err := windows.GetProcessTimes(windows.CurrentProcess(), &created, &exited, &kernel, &user); err != nil {
		t.Fatal(err)
	}
	start := int64(created.HighDateTime)<<32 | int64(created.LowDateTime)
	pid := os.Getpid()

	write := func(name, entrypoint string, pid int, procStart int64) {
		body := fmt.Sprintf(`{"pid":%d,"kind":"interactive","entrypoint":%q,"status":"idle","procStart":%d}`, pid, entrypoint, procStart)
		if err := os.WriteFile(filepath.Join(dir, name+".json"), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("ide", "claude-vscode", pid, start)
	write("terminal", "cli", pid, start)
	write("reused-pid", "claude-vscode", pid, start-10_000_000) // 1s off
	write("dead", "claude-vscode", 0x7ffffff0, start)

	got := ideSessions()
	if len(got) != 1 || got[0].PID != pid || got[0].Entrypoint != "claude-vscode" {
		t.Fatalf("ideSessions() = %+v, want only the live claude-vscode session", got)
	}
}
