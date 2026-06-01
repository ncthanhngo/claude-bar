package mcp

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// TestGatewayToolsListExposesEveryConnector exercises the MCP server's
// tools/list handler without going through stdio. Confirms every cb_* tool
// is registered and uses the cb_ prefix.
func TestGatewayToolsListExposesEveryConnector(t *testing.T) {
	// BuildServer now skips disabled connectors so we seed an account with
	// every service Enabled — mirroring the real "user has connected
	// everything" path the assertions below describe.
	gw := newSmokeGateway(1, false)
	srv := gw.BuildServer()

	msg := json.RawMessage(`{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}`)
	resp := srv.HandleMessage(context.Background(), msg)
	if resp == nil {
		t.Fatal("nil response")
	}
	b, _ := json.Marshal(resp)
	out := string(b)

	wanted := []string{
		"cb_slack_list_channels",
		"cb_slack_search_messages",
		"cb_slack_get_thread",
		"cb_clickup_list_workspaces",
		"cb_clickup_list_tasks",
		"cb_clickup_get_task",
		"cb_clickup_get_doc",
		"cb_gdrive_search_files",
		"cb_gdrive_get_file_metadata",
		"cb_gdrive_get_doc_text",
		"cb_gdrive_share_file",
		"cb_gsheets_create_spreadsheet",
		"cb_gsheets_create_from_csv",
		"cb_gsheets_update_values",
		"cb_gsheets_append_values",
	}
	for _, name := range wanted {
		if !strings.Contains(out, name) {
			t.Errorf("tools/list missing %q in:\n%s", name, out)
		}
	}
	// Make sure no unprefixed tool slipped in.
	for _, banned := range []string{`"slack_`, `"clickup_`, `"gdrive_`} {
		if strings.Contains(out, banned) {
			t.Errorf("found unprefixed tool name %q (must use cb_ prefix)", banned)
		}
	}
}

// TestGatewayCallToolFailsClosedWhenNoActiveAccount calls a Slack tool with
// no active account configured and asserts the response is a fail-closed
// error that does not leak which other accounts have the connector.
func TestGatewayCallToolFailsClosedWhenNoActiveAccount(t *testing.T) {
	// Seed the shared connector as Enabled so the Slack tool is registered
	// and reachable via tools/call. ActiveAccountNumber stays 0, so the
	// resolver returns ErrNoActiveAccount → connector_unavailable.
	gw := newSmokeGatewayWithSharedEnabled()
	srv := gw.BuildServer()

	msg := json.RawMessage(`{
		"jsonrpc":"2.0","id":2,
		"method":"tools/call",
		"params":{"name":"cb_slack_list_channels","arguments":{}}
	}`)
	resp := srv.HandleMessage(context.Background(), msg)
	b, _ := json.Marshal(resp)
	out := string(b)

	if !strings.Contains(out, "connector_unavailable") {
		t.Errorf("expected connector_unavailable, got %s", out)
	}
	// Must NOT reveal account list.
	if strings.Contains(out, "account 1") || strings.Contains(out, "account 2") {
		t.Errorf("error must not reveal account numbers, got %s", out)
	}
}

// TestResolverPicksUpActiveAccountSwitchWithoutRestart is the load-bearing
// account-switch guarantee from the threat model: the same MCP session can
// switch active account at the menu bar and the next tool-call resolution
// uses the new account's connector profile.
func TestResolverPicksUpActiveAccountSwitchWithoutRestart(t *testing.T) {
	reg := domain.NewRegistry()
	reg.ActiveAccountNumber = 1
	reg.Sequence = []int{1, 2}
	reg.Accounts[1] = &domain.Account{
		Number: 1, Email: "a@x", CreatedAt: time.Now(),
		MCPConnectors: domain.AccountConnectors{
			domain.MCPServiceSlack: &domain.MCPConnector{Enabled: true},
		},
	}
	reg.Accounts[2] = &domain.Account{
		Number: 2, Email: "b@x", CreatedAt: time.Now(),
		MCPConnectors: domain.AccountConnectors{
			domain.MCPServiceSlack: &domain.MCPConnector{Enabled: true},
		},
	}
	fr := &fakeRegistry{reg: reg}
	secrets := fakeSecrets{
		key(1, domain.MCPServiceSlack): "xoxp-account-1",
		key(2, domain.MCPServiceSlack): "xoxp-account-2",
	}
	r := &Resolver{Registry: fr, Secrets: secrets}

	cc1, err := r.Resolve(context.Background(), domain.MCPServiceSlack)
	if err != nil || cc1.Payload != "xoxp-account-1" {
		t.Fatalf("first resolve: %+v err=%v", cc1, err)
	}

	// Simulate the menu bar switching active account. No restart, no rebuild.
	reg.ActiveAccountNumber = 2

	cc2, err := r.Resolve(context.Background(), domain.MCPServiceSlack)
	if err != nil || cc2.Payload != "xoxp-account-2" {
		t.Fatalf("after switch: %+v err=%v", cc2, err)
	}
	if cc2.AccountNumber != 2 {
		t.Errorf("expected AccountNumber=2, got %d", cc2.AccountNumber)
	}
}

func newSmokeGateway(activeAccount int, withSecret bool) *Gateway {
	reg := domain.NewRegistry()
	reg.ActiveAccountNumber = activeAccount
	if activeAccount > 0 {
		acc := &domain.Account{Number: activeAccount, Email: "x@y", CreatedAt: time.Now()}
		acc.MCPConnectors = domain.AccountConnectors{}
		for _, s := range domain.AllMCPServices {
			acc.MCPConnectors[s] = &domain.MCPConnector{Enabled: true}
		}
		reg.Accounts[activeAccount] = acc
		reg.Sequence = []int{activeAccount}
	}
	secrets := fakeSecrets{}
	if withSecret && activeAccount > 0 {
		for _, s := range domain.AllMCPServices {
			secrets[key(activeAccount, s)] = "token"
		}
	}
	gw := newTestGateway()
	gw.Resolver = &Resolver{Registry: &fakeRegistry{reg: reg}, Secrets: secrets}
	return gw
}

// newSmokeGatewayWithSharedEnabled wires a registry that has every service
// Enabled on the shared meta but no active account. Lets us register tools
// in tools/list (so tools/call can reach them) while still triggering the
// resolver's ErrNoActiveAccount path.
func newSmokeGatewayWithSharedEnabled() *Gateway {
	reg := domain.NewRegistry()
	reg.SharedMCPConnectors = domain.AccountConnectors{}
	for _, s := range domain.AllMCPServices {
		reg.SharedMCPConnectors[s] = &domain.MCPConnector{Enabled: true}
	}
	gw := newTestGateway()
	gw.Resolver = &Resolver{Registry: &fakeRegistry{reg: reg}, Secrets: fakeSecrets{}}
	return gw
}
