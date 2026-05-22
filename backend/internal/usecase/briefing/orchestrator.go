package briefing

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/mcp"
)

// Orchestrator fans out the 4 MCP sources in parallel for one briefing.
type Orchestrator struct {
	Gateway *mcp.Gateway
	// PerSourceTimeout caps each source's wall clock. Default 15s.
	PerSourceTimeout time.Duration
}

// NewOrchestrator wires the gateway in. accountNumber is captured at
// construction in the caller to keep the run pinned to one account.
func NewOrchestrator(g *mcp.Gateway) *Orchestrator {
	return &Orchestrator{Gateway: g, PerSourceTimeout: 15 * time.Second}
}

// Fetch runs all 4 sources concurrently with fail-soft semantics.
func (o *Orchestrator) Fetch(ctx context.Context, accountNumber int) *RawSourceData {
	raw := &RawSourceData{
		AccountNumber: accountNumber,
		FetchedAt:     time.Now().UTC(),
		Errors:        map[string]string{},
		Health:        map[string]string{},
	}
	var mu sync.Mutex
	var wg sync.WaitGroup

	runOne := func(name string, fn func(ctx context.Context) (any, error), assign func(any)) {
		defer wg.Done()
		sCtx, cancel := context.WithTimeout(ctx, o.PerSourceTimeout)
		defer cancel()
		val, err := fn(sCtx)
		mu.Lock()
		defer mu.Unlock()
		if err != nil {
			raw.Errors[name] = mcp.Redact(err.Error())
			raw.Health[name] = healthFromErr(err)
			return
		}
		assign(val)
		raw.Health[name] = "ok"
	}

	wg.Add(4)
	go runOne("gmail",
		func(c context.Context) (any, error) { return FetchGmail(c, o.Gateway) },
		func(v any) { raw.Gmail = v.([]GmailItem) })
	go runOne("gcal",
		func(c context.Context) (any, error) { return FetchGCal(c, o.Gateway) },
		func(v any) { raw.GCal = v.([]CalItem) })
	go runOne("clickup",
		func(c context.Context) (any, error) { return FetchClickUp(c, o.Gateway) },
		func(v any) { raw.ClickUp = v.([]TaskItem) })
	go runOne("slack",
		func(c context.Context) (any, error) { return FetchSlack(c, o.Gateway) },
		func(v any) { raw.Slack = v.([]SlackItem) })

	wg.Wait()
	return raw
}

// healthFromErr maps known errors to UI-friendly health strings.
func healthFromErr(err error) string {
	switch {
	case errors.Is(err, mcp.ErrConnectorUnauthorized):
		return "unauthorized"
	case errors.Is(err, mcp.ErrConnectorDisabled):
		return "disabled"
	case errors.Is(err, mcp.ErrNoActiveAccount):
		return "no_account"
	default:
		return "down"
	}
}
