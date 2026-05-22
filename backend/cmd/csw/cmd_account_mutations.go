package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"strconv"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/keychain"
	"github.com/soi/claude-swap-widget/backend/internal/usecase"
	"github.com/soi/claude-swap-widget/backend/internal/usecase/chat"
)

func runAdd(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("add", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	nickname := fs.String("nickname", "", "optional display name for the account")
	_ = fs.Parse(args)

	res, err := svc.AddAccount(ctx, *nickname)
	if err != nil {
		return err
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(res)
	}
	if res.WasDuplicate {
		fmt.Printf("⚠ Account %s already existed as Account-%d. Backup credentials refreshed.\n",
			res.Account.Email, res.DuplicateOfNum)
	} else {
		fmt.Printf("Added Account-%d (%s).\n", res.Account.Number, res.Account.DisplayName())
	}
	return nil
}

func runRename(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("rename", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	if fs.NArg() < 1 {
		return fmt.Errorf("usage: csw rename <num> [<nickname>]   (empty nickname clears)")
	}
	num, err := strconv.Atoi(fs.Arg(0))
	if err != nil {
		return fmt.Errorf("invalid account number: %s", fs.Arg(0))
	}
	nickname := ""
	if fs.NArg() >= 2 {
		nickname = fs.Arg(1)
	}
	if err := svc.RenameAccount(ctx, num, nickname); err != nil {
		return err
	}
	if *asJSON {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{
			"ok":       true,
			"number":   num,
			"nickname": nickname,
		})
		return nil
	}
	if nickname == "" {
		fmt.Printf("Cleared nickname for Account-%d.\n", num)
	} else {
		fmt.Printf("Renamed Account-%d to %q.\n", num, nickname)
	}
	return nil
}

func runRemove(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("remove", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)

	if fs.NArg() < 1 {
		return fmt.Errorf("usage: csw remove <num>")
	}
	num, err := strconv.Atoi(fs.Arg(0))
	if err != nil {
		return fmt.Errorf("invalid account number: %s", fs.Arg(0))
	}

	// Look up the account's UUID before removal so we can purge its chat
	// data using a stable identifier. Look-up failures are tolerated — we
	// still want the swap-related removal to proceed.
	accountUUID := lookupAccountUUID(ctx, svc, num)

	if err := svc.RemoveAccount(ctx, num); err != nil {
		return err
	}

	// Chat purge runs AFTER the registry / backup deletion. We treat purge
	// errors as warnings — the user-visible operation succeeded; orphaned
	// chat data is recoverable manually if Keychain access flakes.
	if accountUUID != "" {
		opts := chat.PurgeOptions{KeyStore: keychain.NewChatDBKeyStore()}
		if err := chat.PurgeAccount(ctx, accountUUID, opts); err != nil {
			log.Printf("[remove] chat purge for %s failed: %v", accountUUID, err)
		}
	}

	if *asJSON {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": true, "number": num})
		return nil
	}
	fmt.Printf("Removed Account-%d.\n", num)
	return nil
}

// lookupAccountUUID returns the AccountUUID for `num`, preferring the
// claude.json oauthAccount value when the target is currently active and
// falling back to the registry IdentityKey (email|orgUUID) otherwise.
// Mirrors oauth.TokenProvider.accountUUID for chat-storage scoping.
func lookupAccountUUID(ctx context.Context, svc *usecase.Service, num int) string {
	reg, err := svc.Registry.Load(ctx)
	if err != nil || reg == nil {
		return ""
	}
	if num == reg.ActiveAccountNumber {
		if cfg, err := svc.Config.Read(ctx); err == nil && cfg != nil && cfg.OAuthAccount != nil {
			if u := cfg.OAuthAccount.AccountUUID; u != "" {
				return u
			}
		}
	}
	if acc := reg.Accounts[num]; acc != nil {
		return acc.IdentityKey()
	}
	return ""
}
