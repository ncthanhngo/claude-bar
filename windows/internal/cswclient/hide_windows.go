//go:build windows

package cswclient

import (
	"os/exec"
	"syscall"
)

// createNoWindow keeps csw.exe from flashing a console window.
const createNoWindow = 0x08000000

func hideConsole(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
}
