//go:build windows

// Command claudeswap is the Claude Swap notification-area app.
package main

import (
	"os"

	"github.com/ncruces/zenity"

	"github.com/soi/claude-swap-widget/windows/internal/cswclient"
	"github.com/soi/claude-swap-widget/windows/internal/tray"
	"github.com/soi/claude-swap-widget/windows/internal/winutil"
)

func main() {
	if len(os.Args) >= 3 && os.Args[1] == tray.SignInFlag {
		tray.SignInMain(os.Args[2:]) // the tray's sign-in window process
		return
	}
	ok, err := winutil.SingleInstance(`Local\ClaudeSwapTray`)
	if err != nil || !ok {
		return // already running in this session
	}
	csw := winutil.BesideExecutable("csw.exe")
	if _, err := os.Stat(csw); err != nil {
		_ = zenity.Error("csw.exe is missing next to ClaudeSwap.exe. Reinstall Claude Swap.", zenity.Title("Claude Swap"))
		os.Exit(1)
	}
	tray.Run(cswclient.New(csw))
}
