//go:build !windows

package sessions

import "syscall"

// isPIDAlive returns true iff a process with this pid exists. Uses kill(pid, 0)
// which returns EPERM if alive-but-not-ours (still alive), ESRCH if dead.
func isPIDAlive(pid int) bool {
	if pid <= 1 {
		return false
	}
	err := syscall.Kill(pid, 0)
	if err == nil {
		return true
	}
	return err == syscall.EPERM
}
