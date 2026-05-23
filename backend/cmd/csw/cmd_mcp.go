package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/claudeconfig"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/keychain"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/mcp"
	"github.com/soi/claude-swap-widget/backend/internal/usecase"
)

// defaultGDriveClientID is overridable at build time via
//
//	-ldflags="-X main.defaultGDriveClientID=xxxx.apps.googleusercontent.com"
//
// When set, users can connect Google Drive without pasting their own
// client ID. PKCE (S256) is used, so no secret distribution is needed.
var defaultGDriveClientID = ""

func pickGDriveClientID(userArg string) string {
	if userArg != "" {
		return userArg
	}
	return defaultGDriveClientID
}

// cswVersion is overridden at build time via -ldflags; "dev" for local builds.
var cswVersion = "dev"

func runMCP(ctx context.Context, svc *usecase.Service, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw mcp <serve|install|uninstall|status|connectors> [args]")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "serve":
		return runMCPServe(ctx, svc)
	case "install":
		return runMCPInstall(ctx, rest)
	case "uninstall":
		return runMCPUninstall(ctx)
	case "status":
		return runMCPStatus(ctx, rest)
	case "connectors":
		return runMCPConnectors(ctx, svc, rest)
	default:
		return fmt.Errorf("unknown mcp subcommand: %s", sub)
	}
}

func runMCPServe(ctx context.Context, svc *usecase.Service) error {
	// Phase 1 of the Command Center plan: canonicalise per-account MCP
	// secrets under the shared account-key on every boot. Idempotent
	// (sentinel-tracked), retry-safe (sentinel withheld on per-service
	// failure). Best-effort: a migration error must not prevent the
	// gateway from serving — under soft-deprecate the resolver still
	// falls back to per-account entries if shared canonicalisation
	// hasn't completed yet.
	if reg, err := svc.Registry.Load(ctx); err == nil && reg != nil {
		_, _ = keychain.MigrateToShared(ctx, svc.MCPSecrets, reg)
	}
	gw := mcp.New(svc.Registry, svc.MCPSecrets, cswVersion)
	return gw.ServeStdio(ctx)
}

func runMCPInstall(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("install", flag.ExitOnError)
	force := fs.Bool("force", false, "overwrite an existing claude-bar-mcp entry")
	pathOverride := fs.String("path", "", "path to csw binary (default: current executable)")
	_ = fs.Parse(args)
	cswPath := *pathOverride
	if cswPath == "" {
		p, err := os.Executable()
		if err != nil {
			return fmt.Errorf("locate csw binary: %w", err)
		}
		cswPath = p
	}
	store := claudeconfig.New()
	if err := mcp.Install(ctx, store, cswPath, *force); err != nil {
		return err
	}
	fmt.Printf("installed: claude-bar-mcp -> %s mcp serve\n", cswPath)
	return nil
}

func runMCPUninstall(ctx context.Context) error {
	if err := mcp.Uninstall(ctx, claudeconfig.New()); err != nil {
		return err
	}
	fmt.Println("uninstalled: claude-bar-mcp removed from ~/.claude.json")
	return nil
}

func runMCPStatus(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)
	expectedPath, _ := os.Executable()
	st, err := mcp.Status(ctx, claudeconfig.New(), expectedPath)
	if err != nil {
		return err
	}
	envelope := struct {
		Installed              bool   `json:"installed"`
		Command                string `json:"command,omitempty"`
		Conflict               bool   `json:"conflict,omitempty"`
		HasDefaultGDriveClient bool   `json:"hasDefaultGDriveClient"`
	}{
		Installed:              st.Installed,
		Command:                st.Command,
		Conflict:               st.Conflict,
		HasDefaultGDriveClient: defaultGDriveClientID != "",
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(envelope)
	}
	if st.Installed {
		fmt.Printf("installed: %s\n", st.Command)
	} else {
		fmt.Println("not installed")
	}
	if envelope.HasDefaultGDriveClient {
		fmt.Println("gdrive: default client ID is baked in")
	}
	return nil
}

func runMCPConnectors(ctx context.Context, svc *usecase.Service, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw mcp connectors <list|connect|disconnect>")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "list":
		return runMCPConnectorsList(ctx, svc, rest)
	case "connect":
		return runMCPConnectorsConnect(ctx, svc, rest)
	case "disconnect":
		return runMCPConnectorsDisconnect(ctx, svc, rest)
	default:
		return fmt.Errorf("unknown connectors subcommand: %s", sub)
	}
}

func runMCPConnectorsList(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("connectors-list", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)
	out, err := svc.ListMCPConnectors(ctx)
	if err != nil {
		return err
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(out)
	}
	for _, a := range out {
		marker := " "
		if a.Active {
			marker = "▸"
		}
		fmt.Printf("%s %d  %s\n", marker, a.AccountNumber, a.DisplayName)
		for _, c := range a.Connectors {
			state := "off"
			switch {
			case c.NeedsReauth:
				state = "needs reauth"
			case c.Enabled && c.HasSecret:
				state = "connected"
			case c.HasSecret:
				state = "secret only (disabled)"
			}
			fmt.Printf("       %-8s %s\n", c.Service, state)
		}
	}
	return nil
}

func runMCPConnectorsConnect(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("connectors-connect", flag.ExitOnError)
	account := fs.Int("account", -1, "account number")
	shared := fs.Bool("shared", false, "connect once for all Claude Bar accounts on this Mac")
	service := fs.String("service", "", "slack | clickup | gdrive")
	tokenStr := fs.String("token", "", "read token from stdin with --token=-")
	clientID := fs.String("client-id", "", "google OAuth client id (gdrive only)")
	clientSecret := fs.String("client-secret", "", "google OAuth client secret (gdrive desktop clients may require it)")
	displayName := fs.String("name", "", "optional display name shown in widget")
	_ = fs.Parse(args)
	targetAccount, err := mcpTargetAccount(*account, *shared)
	if err != nil {
		return err
	}
	if *service == "" {
		return errors.New("--service is required")
	}
	svcID := domain.MCPService(*service)
	switch svcID {
	case domain.MCPServiceSlack:
		token, err := readToken(*tokenStr)
		if err != nil {
			return err
		}
		vr, err := mcp.VerifySlackToken(ctx, verifyClient(), token)
		if err != nil {
			return fmt.Errorf("verify slack token: %w", err)
		}
		return svc.ConnectMCPConnector(ctx, usecase.ConnectMCPRequest{
			AccountNumber: targetAccount, Service: svcID, Payload: token,
			DisplayName: pickDisplayName(*displayName, vr.DisplayName),
			Account:     vr.Account,
			Verified:    true,
		})
	case domain.MCPServiceClickUp:
		token, err := readToken(*tokenStr)
		if err != nil {
			return err
		}
		vr, err := mcp.VerifyClickUpToken(ctx, verifyClient(), token)
		if err != nil {
			return fmt.Errorf("verify clickup token: %w", err)
		}
		return svc.ConnectMCPConnector(ctx, usecase.ConnectMCPRequest{
			AccountNumber: targetAccount, Service: svcID, Payload: token,
			DisplayName: pickDisplayName(*displayName, vr.DisplayName),
			Account:     vr.Account,
			Verified:    true,
		})
	case domain.MCPServiceGDrive:
		cid := pickGDriveClientID(*clientID)
		if cid == "" {
			return errors.New("--client-id is required for gdrive (no default baked in)")
		}
		res, err := mcp.GDriveStartOAuth(ctx, cid, strings.TrimSpace(*clientSecret), openBrowser)
		if err != nil {
			return err
		}
		vr, vErr := mcp.VerifyGDriveAccess(ctx, verifyClient(), res.Payload.AccessToken)
		if vErr != nil {
			return fmt.Errorf("verify gdrive access: %w", vErr)
		}
		payload, err := res.Payload.Marshal()
		if err != nil {
			return err
		}
		return svc.ConnectMCPConnector(ctx, usecase.ConnectMCPRequest{
			AccountNumber: targetAccount, Service: svcID, Payload: payload,
			DisplayName: pickDisplayName(*displayName, vr.DisplayName),
			Account:     vr.Account,
			Scopes:      []string{"drive.readonly", "calendar.events.readonly", "gmail.readonly"},
			Verified:    true,
		})
	default:
		return fmt.Errorf("unknown service: %s", svcID)
	}
}

func readToken(tokenArg string) (string, error) {
	token := strings.TrimSpace(tokenArg)
	if token != "-" {
		return "", errors.New("--token=- is required; tokens must be read from stdin")
	}
	b, err := io.ReadAll(os.Stdin)
	if err != nil {
		return "", err
	}
	token = strings.TrimSpace(string(b))
	if token == "" {
		return "", errors.New("--token is required (use --token=- to read from stdin)")
	}
	return token, nil
}

func pickDisplayName(user, provider string) string {
	if user != "" {
		return user
	}
	return provider
}

func verifyClient() *http.Client {
	return &http.Client{Timeout: 10 * time.Second}
}

func runMCPConnectorsDisconnect(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("connectors-disconnect", flag.ExitOnError)
	account := fs.Int("account", -1, "account number")
	shared := fs.Bool("shared", false, "disconnect the shared connector")
	service := fs.String("service", "", "slack | clickup | gdrive")
	_ = fs.Parse(args)
	targetAccount, err := mcpTargetAccount(*account, *shared)
	if err != nil {
		return err
	}
	if *service == "" {
		return errors.New("--service is required")
	}
	return svc.DisconnectMCPConnector(ctx, targetAccount, domain.MCPService(*service))
}

func mcpTargetAccount(account int, shared bool) (int, error) {
	if shared {
		if account != -1 {
			return 0, errors.New("use either --shared or --account, not both")
		}
		return 0, nil
	}
	if account <= 0 {
		return 0, errors.New("--account is required, or use --shared")
	}
	return account, nil
}

func openBrowser(url string) error {
	cmd := exec.Command("/usr/bin/open", url)
	return cmd.Start()
}
