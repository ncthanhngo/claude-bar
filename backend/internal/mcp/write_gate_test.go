package mcp

import (
	"context"
	"testing"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
)

func TestRunThroughGateAutoApproveExecutesWithoutGate(t *testing.T) {
	gw := newTestGateway()
	gw.AutoApprove = func(tool string) bool {
		return tool == "cb_slack_post_message"
	}
	called := false

	res, err := gw.runThroughGate(context.Background(), writeGateRequest{
		Tool: "cb_slack_post_message",
		Execute: func(context.Context) (*mcpgo.CallToolResult, error) {
			called = true
			return mcpgo.NewToolResultText("ok"), nil
		},
	})
	if err != nil {
		t.Fatalf("runThroughGate: %v", err)
	}
	if !called {
		t.Fatal("Execute was not called")
	}
	if res == nil || res.IsError {
		t.Fatalf("expected success result, got %+v", res)
	}
}

func TestRunThroughGateAutoApproveDoesNotOpenOtherTools(t *testing.T) {
	gw := newTestGateway()
	gw.AutoApprove = func(tool string) bool {
		return tool == "cb_slack_post_message"
	}
	called := false

	res, err := gw.runThroughGate(context.Background(), writeGateRequest{
		Tool: "cb_slack_reply_thread",
		Execute: func(context.Context) (*mcpgo.CallToolResult, error) {
			called = true
			return mcpgo.NewToolResultText("unexpected"), nil
		},
	})
	if err != nil {
		t.Fatalf("runThroughGate: %v", err)
	}
	if called {
		t.Fatal("Execute was called for non-auto-approved tool")
	}
	if res == nil || !res.IsError {
		t.Fatalf("expected fail-closed error result, got %+v", res)
	}
}
