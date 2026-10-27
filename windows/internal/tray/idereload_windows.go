//go:build windows

package tray

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"golang.org/x/sys/windows"
)

// IDE reload: Claude Code sessions inside VS Code (and other IDE
// extensions) keep the login they started with. After a switch the tray
// ends those sessions' processes and the extension starts them again with
// the new account — the macOS app's fallback (IDEReloader
// .killExtensionSessions). Terminal (`cli`) sessions are left alone: they
// pick up the new login on their next request.

// ideWaitBusy bounds how long a reload waits for a busy session to finish
// its answer before giving up on it.
const ideWaitBusy = 10 * time.Minute

// ideSession is one ~/.claude/sessions/<id>.json written by Claude Code.
type ideSession struct {
	PID        int         `json:"pid"`
	Kind       string      `json:"kind"`
	Entrypoint string      `json:"entrypoint"`
	Status     string      `json:"status"`    // busy | idle | waiting
	ProcStart  json.Number `json:"procStart"` // process creation FILETIME
}

// ideSessions lists live, non-terminal interactive sessions.
func ideSessions() []ideSession {
	home, _ := os.UserHomeDir()
	files, _ := filepath.Glob(filepath.Join(home, ".claude", "sessions", "*.json"))
	var out []ideSession
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var s ideSession
		if json.Unmarshal(data, &s) != nil || s.PID <= 0 {
			continue
		}
		if s.Kind != "interactive" || s.Entrypoint == "" || s.Entrypoint == "cli" {
			continue
		}
		if !sameProcess(s) {
			continue // exited, or its pid now belongs to another process
		}
		out = append(out, s)
	}
	return out
}

// sameProcess checks the pid is alive and is the process the session file
// describes (creation time matches), so a reused pid is never touched.
func sameProcess(s ideSession) bool {
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(s.PID))
	if err != nil {
		return false
	}
	defer windows.CloseHandle(h)
	var created, exited, kernel, user windows.Filetime
	if windows.GetProcessTimes(h, &created, &exited, &kernel, &user) != nil {
		return false
	}
	var code uint32
	if windows.GetExitCodeProcess(h, &code) != nil || code != 259 { // STILL_ACTIVE
		return false
	}
	want, err := strconv.ParseInt(s.ProcStart.String(), 10, 64)
	if err != nil || want == 0 {
		return true // older Claude Code without procStart: trust the pid
	}
	got := int64(created.HighDateTime)<<32 | int64(created.LowDateTime)
	diff := got - want
	return diff > -100_000 && diff < 100_000 // within 10ms
}

// sessionStatus re-reads a session's status ("" if it is gone).
func sessionStatus(pid int) string {
	for _, s := range ideSessions() {
		if s.PID == pid {
			return s.Status
		}
	}
	return ""
}

func endProcess(pid int) bool {
	h, err := windows.OpenProcess(windows.PROCESS_TERMINATE, false, uint32(pid))
	if err != nil {
		return false
	}
	defer windows.CloseHandle(h)
	return windows.TerminateProcess(h, 1) == nil
}

// reloadIDESessions restarts every IDE session now, except busy ones,
// which are restarted once their current answer is done. It returns how
// many were restarted now and how many will be.
func reloadIDESessions(onLater func(pid int, restarted bool)) (now, later int) {
	for _, s := range ideSessions() {
		if s.Status == "busy" {
			later++
			go func(pid int) {
				deadline := time.Now().Add(ideWaitBusy)
				for time.Now().Before(deadline) {
					time.Sleep(2 * time.Second)
					switch sessionStatus(pid) {
					case "":
						onLater(pid, false) // ended on its own
						return
					case "busy":
						continue
					default:
						onLater(pid, endProcess(pid))
						return
					}
				}
				onLater(pid, false)
			}(s.PID)
			continue
		}
		if endProcess(s.PID) {
			now++
		}
	}
	return now, later
}
