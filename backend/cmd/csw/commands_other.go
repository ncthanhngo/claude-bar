//go:build !windows

package main

// platformCommands is nil: every command is available.
var platformCommands map[string]bool
