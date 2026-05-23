package mcp

import (
	"context"
	"time"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
)

// writeGateRequest is the per-call envelope passed to runThroughGate. Args are
// the resolved, ready-to-execute arguments; Summary is the user-facing text
// the gate displays. The execute callback runs only on approval.
type writeGateRequest struct {
	Tool    string
	Risk    Risk
	Origin  Origin
	Summary string
	Args    map[string]any
	Account string

	// Execute the actual provider call. Returned (result, err) is propagated
	// back to the MCP client untouched (apart from audit logging).
	Execute func(ctx context.Context) (*mcpgo.CallToolResult, error)
}

// runThroughGate blocks on GateService approval (if configured), then runs
// the request's Execute callback, then emits one audit event. Cancellation,
// timeout, and missing-emitter all return a user_cancelled tool result —
// never invoking Execute.
//
// When Gateway.Gate is nil (CLI invocation, tests), the call fails closed:
// returns user_cancelled with no provider hit. That's the safe default.
func (g *Gateway) runThroughGate(ctx context.Context, req writeGateRequest) (*mcpgo.CallToolResult, error) {
	prompt := GatePrompt{
		Tool:    req.Tool,
		Risk:    req.Risk,
		Origin:  req.Origin,
		Summary: req.Summary,
		Args:    req.Args,
		Account: req.Account,
	}

	start := time.Now()
	decision := DecisionTimeout
	var execErr error
	var result *mcpgo.CallToolResult

	if g.Gate == nil {
		decision = DecisionCancelled
	} else {
		d, _ := g.Gate.AwaitApproval(ctx, prompt)
		decision = d
	}

	if decision == DecisionApproved {
		result, execErr = req.Execute(ctx)
	}

	g.emitAudit(ctx, req, decision, result, execErr, time.Since(start))

	switch decision {
	case DecisionApproved:
		return result, execErr
	case DecisionTimeout:
		return mcpgo.NewToolResultError("user_cancelled: gate timed out"), nil
	default:
		return mcpgo.NewToolResultError("user_cancelled"), nil
	}
}

func (g *Gateway) emitAudit(ctx context.Context, req writeGateRequest, d Decision, result *mcpgo.CallToolResult, execErr error, latency time.Duration) {
	if g.Audit == nil {
		return
	}
	kind := AuditKindMCPWrite
	if req.Risk == RiskReadSensitive {
		kind = AuditKindMCPReadSensitive
	}
	outcome := "ok"
	switch {
	case d == DecisionCancelled:
		kind = AuditKindGateCancel
		outcome = "user_cancelled"
	case d == DecisionTimeout:
		kind = AuditKindGateTimeout
		outcome = "timeout"
	case execErr != nil:
		outcome = "error:exec"
	case result != nil && result.IsError:
		outcome = "error:tool"
	}
	_ = g.Audit.Write(ctx, AuditEvent{
		Kind:     kind,
		Tool:     req.Tool,
		Account:  req.Account,
		Outcome:  outcome,
		Latency:  latency.Milliseconds(),
		ArgsHash: HashArgs(req.Args),
	})
}
