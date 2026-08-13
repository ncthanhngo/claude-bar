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
	case "ingest-oauth":
		err = runIngestOAuth(ctx, svc, args)
	case "add-oauth":
		err = runAddAccountOAuth(ctx, svc, args)
	case "cloud":
		err = runCloud(ctx, svc, args)
	case "mcp":
		err = runMCP(ctx, svc, args)
	case "usage-stats":
		err = runUsageStats(ctx, svc, args)
	case "refresh-bundle":
		err = runRefreshBundle(ctx, svc, args)
	case "gate":
		err = runGate(ctx, args)
	case "ssh":
		err = runSSH(ctx, args)
	case "citools":
		err = runCITools(ctx, args)
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
  switch <num|label>      Switch active account by number or label (nickname/email)
  add [--nickname=NAME]   Snapshot the currently-logged-in account
  rename <num> <nickname> Rename an account (empty string clears)
  remove <num>            Remove an account (must not be active)
  sessions                Report live Claude Code sessions
  refresh-bundle          One-shot poll payload for the widget: account metadata
                          + sessions report + usage-stats in a single JSON object
  verify                  Verify every account is swap-ready
  refresh-tokens          Refresh OAuth tokens for all inactive accounts
  repair-keychain         Rewrite live Claude Code Keychain item from active backup
  snapshot-active         Snapshot the active account's live creds into its backup slot
  ingest-oauth            Write a fresh OAuth payload (from in-app WebView re-login) to an account's slots
                          (stdin JSON: {accountNum, accessToken, refreshToken, expiresAt, scopes, subscriptionType, expectedEmail})
  add-oauth               Create a NEW account from a WebView OAuth payload (dedupes by email+orgUuid, backup-only)
                          (stdin JSON: {accessToken, refreshToken, expiresAt, scopes, subscriptionType, email, orgUuid, organizationName, nickname})
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
  mcp connectors disconnect --account N --service slack|clickup|gdrive|github     (soft — keeps saved credential)
  mcp connectors reconnect --account N --service slack|clickup|gdrive|github      (verify+enable saved credential)
  mcp connectors forget --account N --service slack|clickup|gdrive|github         (hard delete — wipes Keychain payload)
  mcp connectors set-enabled --account N --service slack|clickup|gdrive|github --enabled=true|false
  help                    Show this help

All commands accept --json for machine-readable output.`)
}
