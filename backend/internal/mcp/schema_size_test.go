package mcp

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// TestGitHubSchemaSize guards the GitHub tools/list payload against silent
// regression. Every byte here ships in the Claude Code system prompt on
// every message in the session, so a careless "let me add a 3-sentence
// description" can cost the user real money over a workday.
//
// Budget: the post-slim payload measured 12,419 bytes (~3,100 tokens) for
// 28 tools. Cap set at 14,000 bytes so small future additions (1-2 fields)
// stay green, but a regression to the old verbose style (~20k bytes) fails
// loudly. Bump only when you've consciously added tools, not when you've
// padded descriptions.
func TestGitHubSchemaSize(t *testing.T) {
	reg := domain.NewRegistry()
	reg.SharedMCPConnectors = domain.AccountConnectors{
		domain.MCPServiceGitHub: &domain.MCPConnector{Enabled: true},
	}
	gw := newTestGateway()
	gw.Resolver = &Resolver{Registry: &fakeRegistry{reg: reg}, Secrets: fakeSecrets{}}
	srv := gw.BuildServer()
	msg := json.RawMessage(`{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}`)
	resp := srv.HandleMessage(context.Background(), msg)
	b, _ := json.Marshal(resp)
	out := string(b)
	count := strings.Count(out, `"name":"cb_github_`)
	t.Logf("github tools=%d bytes=%d approx_tokens=%d", count, len(out), len(out)/4)
	const budgetBytes = 14000
	if len(out) > budgetBytes {
		t.Errorf("github tools/list payload %d bytes exceeds %d byte budget — slim descriptions or split the toolset", len(out), budgetBytes)
	}
}
