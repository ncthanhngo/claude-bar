//go:build !windows

package cswclient

import "os/exec"

func hideConsole(*exec.Cmd) {}
