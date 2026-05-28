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

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/claudeconfig"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/gateipc"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/keychain"
	sshadp "github.com/soi/claude-swap-widget/backend/internal/adapter/ssh"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/mcp"
	"github.com/soi/claude-swap-widget/backend/internal/usecase"
	"path/filepath"
)

// defaultGDriveClientID is overridable at build time via
//
//	-ldflags="-X main.defaultGDriveClientID=xxxx.apps.googleusercontent.com"
//
// When set, users can connect Google Drive without pasting their own
// client ID. PKCE (S256) is used, so no secret distribution is needed.
var defaultGDriveClientID = ""

// defaultGitHubClientID / defaultGitHubClientSecret are similarly overridable
// at build time for the bundled OAuth App.
var (
	defaultGitHubClientID     = ""
	defaultGitHubClientSecret = ""
)

func pickGDriveClientID(userArg string) string {
	if userArg != "" {
		return userArg
	}
	return defaultGDriveClientID
}

func pickGitHubOAuth(idArg, secretArg string) (string, string) {
	id := idArg
	if id == "" {
		id = defaultGitHubClientID
	}
	secret := secretArg
	if secret == "" {
		secret = defaultGitHubClientSecret
	}
	return id, secret
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
	case "tools":
		return runMCPTools(ctx, svc, rest)
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
	gw.AutoApprove = autoApproveWriteTool

	// Wire the write-gate IPC bridge. The widget runs the UDS LISTENER
	// (via `csw gate proxy`); every `csw mcp serve` — including those
	// spawned for subagents by Claude Code's Task tool — dials in as a
	// client. Previously the MCP server held the listener and a second
	// instance would silently replace the first, leaving subagent prompts
	// stranded (issue #21). Audit writer is process-wide append-only.
	// Both nil-safe: writer/gate failures must not block MCP stdio (the
	// LLM client times out cleanly via gate timeout).
	if aw, _ := mcp.DefaultAuditWriter(); aw != nil {
		gw.Audit = aw
	}
	gw.Gate = mcp.NewGateService(nil)
	if err := adapter.EnsureDataDir(); err == nil {
		dialer := gateipc.NewDialEmitter(adapter.GateSocketFile(), gw.Gate)
		gw.Gate.Emitter = dialer
		dialer.Start(ctx)
	}

	// SSH host store — Phase 3. File is created lazily on first Put.
	gw.SSHStore = sshadp.NewHostStore(filepath.Join(adapter.WidgetDataDir(), "ssh", "hosts.json"))

	// ControlMaster reuse — keeps a single ssh TCP connection per host so
	// every cb_ssh_exec / cb_ssh_tail call after the first one skips the
	// auth round-trip. Stale socket sweep at boot removes orphans from a
	// previous hard kill.
	cm := sshadp.NewControlMaster(filepath.Join(adapter.WidgetDataDir(), "ssh"))
	_, _ = cm.Sweep(ctx)
	sshadp.ActiveControlMaster = cm

	// GitLab instance registry — Phase 7. PATs live in Keychain under
	// the multi-token format (claude-bar-mcp:shared:gitlab:<instanceId>).
	gw.GitLabInstances = mcp.NewGitLabInstanceStore(filepath.Join(adapter.WidgetDataDir(), "gitlab-instances.json"))

	// Bitwarden session — Phase 9. 15-minute idle auto-lock. The widget
	// unlock command writes the session token to a per-user file 0600 so
	// the MCP server (a different process) can read it on boot. Reload
	// is cheap; checked on every tool call via the file mtime.
	gw.BWSession = mcp.NewBitwardenSession(15 * time.Minute)
	if tok, err := os.ReadFile(filepath.Join(adapter.WidgetDataDir(), "bw-session")); err == nil {
		gw.BWSession.Unlock(strings.TrimSpace(string(tok)))
	}

	return gw.ServeStdio(ctx)
}

type mcpWritePolicy struct {
	AutoApproveSlackPostMessage bool `json:"autoApproveSlackPostMessage"`
}

func autoApproveWriteTool(tool string) bool {
	if tool != "cb_slack_post_message" {
		return false
	}
	b, err := os.ReadFile(adapter.MCPWritePolicyFile())
	if err != nil {
		return false
	}
	var p mcpWritePolicy
	if err := json.Unmarshal(b, &p); err != nil {
		return false
	}
	return p.AutoApproveSlackPostMessage
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
		return errors.New("usage: csw mcp connectors <list|connect|disconnect|reconnect|forget|set-enabled>")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "list":
		return runMCPConnectorsList(ctx, svc, rest)
	case "connect":
		return runMCPConnectorsConnect(ctx, svc, rest)
	case "disconnect":
		return runMCPConnectorsDisconnect(ctx, svc, rest)
	case "reconnect":
		return runMCPConnectorsReconnect(ctx, svc, rest)
	case "forget":
		return runMCPConnectorsForget(ctx, svc, rest)
	case "set-enabled":
		return runMCPConnectorsSetEnabled(ctx, svc, rest)
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
	service := fs.String("service", "", "slack | clickup | gdrive | github")
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
			Scopes:      []string{"drive.readonly", "drive.file", "calendar.events.readonly", "gmail.readonly", "spreadsheets"},
			Verified:    true,
		})
	case domain.MCPServiceGitHub:
		// Two supported credential paths: a personal access token piped over
		// stdin (--token=-) or the full OAuth App loopback flow when the user
		// supplies --client-id / --client-secret. PAT is the cheap path the
		// widget Connect sheet exposes; OAuth remains for users who want
		// auto-refresh and a bundled app.
		if strings.TrimSpace(*tokenStr) != "" {
			token, err := readToken(*tokenStr)
			if err != nil {
				return err
			}
			vr, err := mcp.VerifyGitHubToken(ctx, verifyClient(), token)
			if err != nil {
				return fmt.Errorf("verify github token: %w", err)
			}
			payload := &mcp.GitHubPayload{
				AccessToken: token,
				Login:       vr.Account,
				Scope:       strings.Join(vr.Scopes, ","),
			}
			marshalled, err := payload.Marshal()
			if err != nil {
				return err
			}
			scopes := vr.Scopes
			if len(scopes) == 0 {
				scopes = []string{"pat"}
			}
			return svc.ConnectMCPConnector(ctx, usecase.ConnectMCPRequest{
				AccountNumber: targetAccount, Service: svcID, Payload: marshalled,
				DisplayName: pickDisplayName(*displayName, vr.DisplayName),
				Account:     vr.Account,
				Scopes:      scopes,
				Verified:    true,
			})
		}
		cid, csecret := pickGitHubOAuth(strings.TrimSpace(*clientID), strings.TrimSpace(*clientSecret))
		if cid == "" {
			return errors.New("--client-id is required for github (or supply --token=- to use a personal access token, or build with -X main.defaultGitHubClientID)")
		}
		if csecret == "" {
			return errors.New("--client-secret is required for github OAuth App")
		}
		res, err := mcp.GitHubStartOAuth(ctx, cid, csecret, openBrowser)
		if err != nil {
			return err
		}
		payload, err := res.Payload.Marshal()
		if err != nil {
			return err
		}
		return svc.ConnectMCPConnector(ctx, usecase.ConnectMCPRequest{
			AccountNumber: targetAccount, Service: svcID, Payload: payload,
			DisplayName: pickDisplayName(*displayName, "GitHub"),
			Scopes:      []string{"repo"},
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
	service := fs.String("service", "", "slack | clickup | gdrive | github")
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

// runMCPConnectorsForget hard-deletes the Keychain payload AND removes
// the registry entry. Used when the user explicitly wants to wipe a
// saved credential — security rotation, dropping a connector entirely,
// removing leaked secrets. The everyday Disconnect button uses the
// soft path that preserves the credential for Reconnect.
func runMCPConnectorsForget(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("connectors-forget", flag.ExitOnError)
	account := fs.Int("account", -1, "account number")
	shared := fs.Bool("shared", false, "forget the shared connector")
	service := fs.String("service", "", "slack | clickup | gdrive | github | gitlab | bitwarden")
	_ = fs.Parse(args)
	targetAccount, err := mcpTargetAccount(*account, *shared)
	if err != nil {
		return err
	}
	if *service == "" {
		return errors.New("--service is required")
	}
	return svc.ForgetMCPConnector(ctx, targetAccount, domain.MCPService(*service))
}

func runMCPTools(ctx context.Context, svc *usecase.Service, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw mcp tools <list|set-enabled>")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "list":
		return runMCPToolsList(ctx, svc, rest)
	case "set-enabled":
		return runMCPToolsSetEnabled(ctx, svc, rest)
	default:
		return fmt.Errorf("unknown tools subcommand: %s", sub)
	}
}

func runMCPToolsList(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("tools-list", flag.ExitOnError)
	service := fs.String("service", "", "slack | clickup | gdrive | github | gitlab | bitwarden")
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)
	if *service == "" {
		return errors.New("--service is required")
	}
	tools, err := svc.ListMCPTools(ctx, domain.MCPService(*service))
	if err != nil {
		return err
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(tools)
	}
	for _, t := range tools {
		mark := " "
		if t.Enabled {
			mark = "✓"
		}
		fmt.Printf("  %s [%s] %-36s %s\n", mark, t.Category, t.ID, t.Label)
	}
	return nil
}

func runMCPToolsSetEnabled(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("tools-set-enabled", flag.ExitOnError)
	tool := fs.String("tool", "", "tool ID, e.g. cb_github_get_pr")
	enabled := fs.Bool("enabled", true, "true to enable, false to disable")
	_ = fs.Parse(args)
	if *tool == "" {
		return errors.New("--tool is required")
	}
	return svc.SetMCPToolEnabled(ctx, *tool, *enabled)
}

func runMCPConnectorsSetEnabled(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("connectors-set-enabled", flag.ExitOnError)
	account := fs.Int("account", -1, "account number")
	shared := fs.Bool("shared", false, "target the shared connector")
	service := fs.String("service", "", "slack | clickup | gdrive | github | gitlab | bitwarden")
	enabled := fs.Bool("enabled", true, "true to enable, false to disable")
	_ = fs.Parse(args)
	targetAccount, err := mcpTargetAccount(*account, *shared)
	if err != nil {
		return err
	}
	if *service == "" {
		return errors.New("--service is required")
	}
	return svc.SetMCPConnectorEnabled(ctx, targetAccount, domain.MCPService(*service), *enabled)
}

// runMCPConnectorsReconnect tries to bring a soft-disconnected connector
// back online without prompting the user for fresh credentials. The
// Keychain payload from the prior session is re-verified against the
// provider's API; on success the connector's Enabled flag flips back to
// true. On verification failure the function exits with code 2 so the
// Swift caller can fall through to the paste-token / OAuth sheet.
//
// Exit codes:
//
//	0 — verified and re-enabled
//	2 — credential present but invalid (caller should prompt for new)
//	1 — anything else (no saved credential, missing flags, IO error)
func runMCPConnectorsReconnect(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("connectors-reconnect", flag.ExitOnError)
	account := fs.Int("account", -1, "account number")
	shared := fs.Bool("shared", false, "target the shared connector")
	service := fs.String("service", "", "slack | clickup | gdrive | github")
	_ = fs.Parse(args)
	targetAccount, err := mcpTargetAccount(*account, *shared)
	if err != nil {
		return err
	}
	if *service == "" {
		return errors.New("--service is required")
	}
	svcID := domain.MCPService(*service)

	payload, err := svc.MCPSecrets.Read(ctx, targetAccount, svcID)
	if err != nil {
		return fmt.Errorf("read mcp secret: %w", err)
	}
	if payload == "" {
		return fmt.Errorf("no saved credential for %s — run `csw mcp connectors connect` first", *service)
	}

	verifyErr := verifySavedMCPCredential(ctx, svc, targetAccount, svcID, payload)
	if verifyErr != nil {
		// Mark as needing re-auth so the UI status pill reflects reality.
		_ = svc.MarkMCPNeedsReauth(ctx, targetAccount, svcID)
		fmt.Fprintf(os.Stderr, "reconnect failed: %v\n", verifyErr)
		os.Exit(2)
	}
	if err := svc.SetMCPConnectorEnabled(ctx, targetAccount, svcID, true); err != nil {
		return fmt.Errorf("set enabled: %w", err)
	}
	fmt.Println("reconnected")
	return nil
}

// verifySavedMCPCredential dispatches to the per-service Verify* helper
// using the payload already on disk. GDrive needs a refresh round-trip
// to mint an access token before the /about probe; the refreshed token
// is best-effort persisted back so the next tool call doesn't re-refresh.
func verifySavedMCPCredential(ctx context.Context, svc *usecase.Service, accountNum int, svcID domain.MCPService, payload string) error {
	switch svcID {
	case domain.MCPServiceSlack:
		_, err := mcp.VerifySlackToken(ctx, verifyClient(), payload)
		return err
	case domain.MCPServiceClickUp:
		_, err := mcp.VerifyClickUpToken(ctx, verifyClient(), payload)
		return err
	case domain.MCPServiceGitHub:
		_, err := mcp.VerifyGitHubToken(ctx, verifyClient(), payload)
		return err
	case domain.MCPServiceGDrive:
		gp, err := mcp.UnmarshalGDrivePayload(payload)
		if err != nil {
			return fmt.Errorf("decode gdrive payload: %w", err)
		}
		access, updated, err := mcp.RefreshGDriveAccessToken(ctx, gp)
		if err != nil {
			return fmt.Errorf("gdrive refresh: %w", err)
		}
		if updated != nil {
			if marshalled, mErr := updated.Marshal(); mErr == nil {
				_ = svc.MCPSecrets.Write(ctx, accountNum, svcID, marshalled)
			}
		}
		_, err = mcp.VerifyGDriveAccess(ctx, verifyClient(), access)
		return err
	default:
		return fmt.Errorf("reconnect not supported for %s — disconnect + connect manually", svcID)
	}
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
