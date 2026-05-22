package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/usecase"
)

// runCloud dispatches cloud sub-commands.
//
// Sub-commands:
//
//	status                — bundle metadata + backup count + last-seen seq
//	push                  — encrypt local accounts to iCloud (reads passphrase from stdin)
//	pull                  — restore from current bundle (anti-rollback enforced)
//	forget                — delete bundle + backups + local sync state
//	list-backups          — list current bundle (slot 0) and ring-buffer copies; reads passphrase if provided on stdin to decrypt and reveal seq
//	restore-backup <slot> — pull from a specific backup slot (bypasses anti-rollback)
func runCloud(ctx context.Context, svc *usecase.Service, args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: csw cloud <status|push|pull|forget|list-backups|restore-backup|preview|pull-selective> [args] [--json]")
	}

	jsonOut := len(args) > 1 && args[len(args)-1] == "--json"
	sub := args[0]

	switch sub {
	case "status":
		res, err := svc.CloudStatus(ctx)
		if err != nil {
			return err
		}
		if jsonOut {
			return json.NewEncoder(os.Stdout).Encode(res)
		}
		if !res.Exists {
			fmt.Printf("No bundle found at:\n  %s\n", res.Path)
			if res.BackupCount > 0 {
				fmt.Printf("Backups available: %d (run `csw cloud list-backups`)\n", res.BackupCount)
			}
			return nil
		}
		fmt.Printf("Bundle: %s\nLast pushed: %s  (%d KB)\nBackups: %d   Last-seen seq: %d\n",
			res.Path, res.PushedAt.Format("2006-01-02 15:04:05 UTC"), res.SizeKB,
			res.BackupCount, res.LastSeenSeq)
		return nil

	case "list-backups":
		// Passphrase is optional: with it we can decrypt and show seq + pushedAt
		// embedded in each bundle. Without, only file metadata is shown.
		pass, _ := readPassphraseOptional("Passphrase (blank for metadata-only): ")
		backups, err := svc.CloudListBackups(ctx, pass)
		if err != nil {
			return err
		}
		if jsonOut {
			return json.NewEncoder(os.Stdout).Encode(backups)
		}
		if len(backups) == 0 {
			fmt.Println("No bundles or backups present.")
			return nil
		}
		for _, b := range backups {
			label := "current"
			if b.Slot > 0 {
				label = fmt.Sprintf("backup #%d", b.Slot)
			}
			line := fmt.Sprintf("  slot %d (%s): %s  %d KB  mtime=%s",
				b.Slot, label, b.Path, b.SizeKB,
				b.FileModTime.Format("2006-01-02 15:04:05 UTC"))
			if b.Decrypted {
				line += fmt.Sprintf("  seq=%d  pushed=%s  accounts=%d",
					b.Seq, b.PushedAtInBundle.Format("2006-01-02 15:04:05 UTC"), b.AccountCount)
			}
			fmt.Println(line)
		}
		return nil

	case "restore-backup":
		if len(args) < 2 {
			return fmt.Errorf("usage: csw cloud restore-backup <slot> [--json]")
		}
		slot, err := strconv.Atoi(args[1])
		if err != nil {
			return fmt.Errorf("slot must be an integer: %w", err)
		}
		pass, err := readPassphrase("Passphrase: ")
		if err != nil {
			return err
		}
		if err := svc.CloudRestoreBackup(ctx, pass, slot); err != nil {
			return err
		}
		if jsonOut {
			return json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": true, "slot": slot})
		}
		fmt.Printf("Accounts restored from slot %d.\n", slot)
		return nil

	case "push":
		pass, err := readPassphrase("Passphrase: ")
		if err != nil {
			return err
		}
		if err := svc.CloudPush(ctx, pass); err != nil {
			return err
		}
		if jsonOut {
			return json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": true})
		}
		fmt.Println("Bundle pushed to iCloud Drive.")
		return nil

	case "pull":
		pass, err := readPassphrase("Passphrase: ")
		if err != nil {
			return err
		}
		if err := svc.CloudPull(ctx, pass); err != nil {
			return err
		}
		if jsonOut {
			return json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": true})
		}
		fmt.Println("Accounts restored from iCloud Drive.")
		return nil

	case "preview":
		// Optional slot positional arg before --json. Defaults to 0 (current bundle).
		slot := 0
		if len(args) >= 2 && args[1] != "--json" {
			n, err := strconv.Atoi(args[1])
			if err != nil {
				return fmt.Errorf("slot must be an integer: %w", err)
			}
			slot = n
		}
		pass, err := readPassphrase("Passphrase: ")
		if err != nil {
			return err
		}
		rows, err := svc.CloudPreview(ctx, pass, slot)
		if err != nil {
			return err
		}
		if jsonOut {
			return json.NewEncoder(os.Stdout).Encode(rows)
		}
		if len(rows) == 0 {
			fmt.Println("No accounts in bundle.")
			return nil
		}
		for _, r := range rows {
			fmt.Printf("  [%s] %s  local=%s  remote=%s\n",
				r.Status, r.Email,
				formatTimeOrDash(r.LocalCreatedAt),
				formatTimeOrDash(r.RemoteCreatedAt))
		}
		return nil

	case "pull-selective":
		// Optional slot positional arg. stdin: line 1 = passphrase, line 2 = JSON
		// array of identity strings ("email|orgUUID").
		slot := 0
		if len(args) >= 2 && args[1] != "--json" {
			n, err := strconv.Atoi(args[1])
			if err != nil {
				return fmt.Errorf("slot must be an integer: %w", err)
			}
			slot = n
		}
		pass, err := readPassphrase("Passphrase: ")
		if err != nil {
			return err
		}
		identsLine, err := readLine("Identities (JSON array): ")
		if err != nil {
			return err
		}
		var identities []string
		if err := json.Unmarshal([]byte(identsLine), &identities); err != nil {
			return fmt.Errorf("decode identities: %w", err)
		}
		if err := svc.CloudPullSelective(ctx, pass, slot, identities); err != nil {
			return err
		}
		if jsonOut {
			return json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": true, "slot": slot, "count": len(identities)})
		}
		fmt.Printf("Restored %d account(s) from slot %d.\n", len(identities), slot)
		return nil

	case "forget":
		if err := svc.CloudForget(ctx); err != nil {
			return err
		}
		if jsonOut {
			return json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": true})
		}
		fmt.Println("Bundle removed from iCloud Drive.")
		return nil

	default:
		return fmt.Errorf("unknown cloud sub-command: %s", sub)
	}
}

// stdinScanner is shared across readPassphrase / readLine in one invocation.
// bufio.Scanner over-reads from its underlying io.Reader, so constructing a
// fresh scanner for each call would drop bytes already buffered from previous
// reads. pull-selective reads passphrase + identities sequentially, so we
// need a single scanner instance.
var stdinScanner *bufio.Scanner

func sharedScanner() *bufio.Scanner {
	if stdinScanner == nil {
		stdinScanner = bufio.NewScanner(os.Stdin)
		stdinScanner.Buffer(make([]byte, 64*1024), 1<<20)
	}
	return stdinScanner
}

// readPassphrase reads a line from stdin (used when called interactively or
// with a pipe from Swift: passphrase written to the process stdin pipe).
func readPassphrase(prompt string) (string, error) {
	fmt.Fprint(os.Stderr, prompt)
	scanner := sharedScanner()
	if !scanner.Scan() {
		return "", fmt.Errorf("no passphrase provided")
	}
	pass := strings.TrimRight(scanner.Text(), "\r\n")
	if pass == "" {
		return "", fmt.Errorf("passphrase must not be empty")
	}
	return pass, nil
}

// readLine reads a single line from stdin (used for non-secret follow-up
// input like the JSON identity list for pull-selective).
func readLine(prompt string) (string, error) {
	fmt.Fprint(os.Stderr, prompt)
	scanner := sharedScanner()
	if !scanner.Scan() {
		return "", fmt.Errorf("no input provided")
	}
	return strings.TrimRight(scanner.Text(), "\r\n"), nil
}

func formatTimeOrDash(t time.Time) string {
	if t.IsZero() {
		return "—"
	}
	return t.UTC().Format("2006-01-02 15:04:05")
}

// readPassphraseOptional is like readPassphrase but treats EOF / empty input
// as a successful empty result rather than an error. Used when a passphrase
// merely unlocks extra detail (e.g. list-backups can run without one).
func readPassphraseOptional(prompt string) (string, error) {
	fmt.Fprint(os.Stderr, prompt)
	scanner := sharedScanner()
	if !scanner.Scan() {
		return "", nil
	}
	return strings.TrimRight(scanner.Text(), "\r\n"), nil
}
