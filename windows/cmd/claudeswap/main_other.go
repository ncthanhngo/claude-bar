//go:build !windows

// Command claudeswap is the Claude Swap notification-area app (Windows only).
package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Fprintln(os.Stderr, "claudeswap runs on Windows only; on macOS use Claude Bar.")
	os.Exit(1)
}
