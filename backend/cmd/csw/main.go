// Command csw is the Claude Swap Widget backend CLI.
//
// It is invoked both standalone (by humans) and as a subprocess by the Swift
// widget. Every subcommand supports --json for machine-readable output.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/soi/claude-swap-widget/backend/internal/usecase"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	svc := usecase.NewMacOSService()
	cmd := os.Args[1]
	args := os.Args[2:]

	var err error
	switch cmd {
	case "list":
		err = runList(ctx, svc, args)
	case "switch":
		err = runSwitch(ctx, svc, args)
	case "add":
		err = runAdd(ctx, svc, args)
	case "rename":
		err = runRename(ctx, svc, args)
	case "remove":
		err = runRemove(ctx, svc, args)
	case "sessions":
		err = runSessions(ctx, svc, args)
	case "active":
		err = runActive(ctx, svc, args)
	case "verify":
		err = runVerify(ctx, svc, args)
	case "refresh-tokens":
		err = runRefreshTokens(ctx, svc, args)
	case "repair-keychain":
		err = runRepairKeychain(ctx, svc, args)
	case "snapshot-active":
		err = runSnapshotActive(ctx, svc, args)
	case "cloud":
		err = runCloud(ctx, svc, args)
	case "mcp":
		err = runMCP(ctx, svc, args)
	case "briefing":
		err = runBriefing(ctx, svc, args)
	case "chat":
		err = runChat(ctx, svc, args)
	case "usage-stats":
		err = runUsageStats(ctx, svc, args)
	case "gate":
		err = runGate(ctx, args)
	case "ssh":
		err = runSSH(ctx, args)
	case "gitlab":
		err = runGitLab(ctx, svc, args)
	case "bw":
		err = runBW(ctx, args)
	case "audit":
		err = runAudit(ctx, args)
	case "repomap":
		err = runRepomap(ctx, args)
	case "help", "-h", "--help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", cmd)
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `csw — Claude Swap Widget backend

Commands:
  list                    List all managed accounts with usage
  active                  Print the active account number
  switch <num>            Switch active account to <num>
  add [--nickname=NAME]   Snapshot the currently-logged-in account
  rename <num> <nickname> Rename an account (empty string clears)
  remove <num>            Remove an account (must not be active)
  sessions                Report live Claude Code sessions
  verify                  Verify every account is swap-ready
  refresh-tokens          Refresh OAuth tokens for all inactive accounts
  repair-keychain         Rewrite live Claude Code Keychain item from active backup
  snapshot-active         Snapshot the active account's live creds into its backup slot
  cloud status            Show iCloud Drive bundle status
  cloud push              Encrypt and push accounts to iCloud Drive
  cloud pull              Restore accounts from iCloud Drive bundle
  cloud forget            Delete the bundle from iCloud Drive
  mcp serve               Run the local MCP gateway over stdio
  mcp install [--force]   Wire claude-bar-mcp into ~/.claude.json
  mcp uninstall           Remove claude-bar-mcp from ~/.claude.json
  mcp status              Show gateway install state
  mcp connectors list     List connectors per account
  mcp connectors connect --account N --service slack|clickup|gdrive|github [--token=- | --client-id ID]
  mcp connectors disconnect --account N --service slack|clickup|gdrive|github
  mcp connectors set-enabled --account N --service slack|clickup|gdrive|github|gitlab --enabled true|false
  briefing run [--force]  Generate today's Daily Briefing (uses MCPs + Claude)
  briefing show [--date]  Read a cached briefing
  briefing schedule get|set|check       Manage briefing cron schedule
  briefing action toggle --id ID --done Mark an action done/undone
  chat conversations list|create|load|rename|delete <conv-id>
                          Manage chat conversations for the active account
  chat send <conv-id>     Stream a reply for the active conversation
                          (stdin JSON: {"text":"…","attachment_ids":[…]})
  chat attach <conv-id> --filename F --media-type M
                          Upload an encrypted attachment (file bytes on stdin)
  chat search --query Q [--limit N]
                          FTS5 search across the active account's messages
  help                    Show this help

All commands accept --json for machine-readable output.`)
}
