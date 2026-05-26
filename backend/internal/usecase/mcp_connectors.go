package usecase

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/mcp"
)

// MCPConnectorSummary is a UI-safe per-service status row.
type MCPConnectorSummary struct {
	Service     domain.MCPService `json:"service"`
	Enabled     bool              `json:"enabled"`
	HasSecret   bool              `json:"hasSecret"`
	DisplayName string            `json:"displayName,omitempty"`
	Account     string            `json:"account,omitempty"`
	NeedsReauth bool              `json:"needsReauth"`
	ConnectedAt time.Time         `json:"connectedAt,omitempty"`
	UsesShared  bool              `json:"usesShared,omitempty"`
}

// MCPAccountSummary lists every supported service for one account, marking
// which are connected and which still need setup.
type MCPAccountSummary struct {
	AccountNumber int                   `json:"accountNumber"`
	DisplayName   string                `json:"displayName"`
	Active        bool                  `json:"active"`
	Shared        bool                  `json:"shared,omitempty"`
	Connectors    []MCPConnectorSummary `json:"connectors"`
}

// ListMCPConnectors returns a summary for every account in the registry.
func (s *Service) ListMCPConnectors(ctx context.Context) ([]MCPAccountSummary, error) {
	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]MCPAccountSummary, 0, len(reg.Sequence)+1)
	shared, err := s.connectorSummaryRows(ctx, 0, reg.SharedMCPConnectors, nil)
	if err != nil {
		return nil, err
	}
	out = append(out, MCPAccountSummary{
		AccountNumber: 0,
		DisplayName:   "Shared for all accounts",
		Shared:        true,
		Connectors:    shared,
	})
	for _, num := range reg.Sequence {
		acc, ok := reg.Accounts[num]
		if !ok {
			continue
		}
		summary := MCPAccountSummary{
			AccountNumber: num,
			DisplayName:   acc.DisplayName(),
			Active:        reg.ActiveAccountNumber == num,
		}
		rows, err := s.connectorSummaryRows(ctx, num, acc.MCPConnectors, reg.SharedMCPConnectors)
		if err != nil {
			return nil, err
		}
		summary.Connectors = rows
		out = append(out, summary)
	}
	return out, nil
}

func (s *Service) connectorSummaryRows(ctx context.Context, accountNum int, metas, fallback domain.AccountConnectors) ([]MCPConnectorSummary, error) {
	rows := make([]MCPConnectorSummary, 0, len(domain.AllMCPServices))
	for _, svc := range domain.AllMCPServices {
		row := MCPConnectorSummary{Service: svc}
		if meta, ok := metas[svc]; ok && meta != nil {
			row.Enabled = meta.Enabled
			row.DisplayName = meta.DisplayName
			row.Account = meta.Account
			row.NeedsReauth = meta.NeedsReauth
			row.ConnectedAt = meta.ConnectedAt
		}
		payload, err := s.MCPSecrets.Read(ctx, accountNum, svc)
		if err != nil {
			return nil, fmt.Errorf("read mcp secret %s/%d: %w", svc, accountNum, err)
		}
		row.HasSecret = payload != ""
		if accountNum != 0 && !row.HasSecret {
			if sharedMeta, ok := fallback[svc]; ok && sharedMeta != nil && sharedMeta.Enabled {
				sharedPayload, err := s.MCPSecrets.Read(ctx, 0, svc)
				if err != nil {
					return nil, fmt.Errorf("read mcp shared secret %s: %w", svc, err)
				}
				row.UsesShared = sharedPayload != ""
			}
		}
		rows = append(rows, row)
	}
	return rows, nil
}

// ConnectMCPRequest carries the payload to persist for a connector.
type ConnectMCPRequest struct {
	AccountNumber int
	Service       domain.MCPService
	Payload       string
	DisplayName   string
	Account       string
	Scopes        []string
	// Verified must be true if the caller validated Payload against the
	// provider. Only then will LastVerified be stamped honestly.
	Verified bool
}

// ConnectMCPConnector stores the provider payload in Keychain and marks the
// connector enabled in the registry. The caller is responsible for having
// validated the payload against the provider (see Verify*).
func (s *Service) ConnectMCPConnector(ctx context.Context, req ConnectMCPRequest) error {
	if err := s.Lock.Acquire(ctx); err != nil {
		return err
	}
	defer s.Lock.Release()

	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return err
	}
	if req.AccountNumber != 0 {
		if _, ok := reg.Accounts[req.AccountNumber]; !ok {
			return fmt.Errorf("account %d not found", req.AccountNumber)
		}
	}
	if err := s.MCPSecrets.Write(ctx, req.AccountNumber, req.Service, req.Payload); err != nil {
		return fmt.Errorf("write mcp secret: %w", err)
	}
	meta := &domain.MCPConnector{
		Enabled:     true,
		DisplayName: req.DisplayName,
		Account:     req.Account,
		Scopes:      req.Scopes,
		ConnectedAt: time.Now().UTC(),
		NeedsReauth: false,
	}
	if req.Verified {
		meta.LastVerified = time.Now().UTC()
	}
	if req.AccountNumber == 0 {
		if reg.SharedMCPConnectors == nil {
			reg.SharedMCPConnectors = domain.AccountConnectors{}
		}
		reg.SharedMCPConnectors[req.Service] = meta
	} else {
		acc := reg.Accounts[req.AccountNumber]
		if acc.MCPConnectors == nil {
			acc.MCPConnectors = domain.AccountConnectors{}
		}
		acc.MCPConnectors[req.Service] = meta
	}
	return s.Registry.Save(ctx, reg)
}

// DisconnectMCPConnector deletes the Keychain secret and clears registry metadata.
func (s *Service) DisconnectMCPConnector(ctx context.Context, accountNum int, svc domain.MCPService) error {
	if err := s.Lock.Acquire(ctx); err != nil {
		return err
	}
	defer s.Lock.Release()

	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return err
	}
	if err := s.MCPSecrets.Delete(ctx, accountNum, svc); err != nil {
		return fmt.Errorf("delete mcp secret: %w", err)
	}
	if accountNum == 0 {
		if reg.SharedMCPConnectors != nil {
			delete(reg.SharedMCPConnectors, svc)
			if len(reg.SharedMCPConnectors) == 0 {
				reg.SharedMCPConnectors = nil
			}
		}
		return s.Registry.Save(ctx, reg)
	}
	acc, ok := reg.Accounts[accountNum]
	if !ok {
		return fmt.Errorf("account %d not found", accountNum)
	}
	if acc.MCPConnectors != nil {
		delete(acc.MCPConnectors, svc)
		if len(acc.MCPConnectors) == 0 {
			acc.MCPConnectors = nil
		}
	}
	return s.Registry.Save(ctx, reg)
}

// MCPToolSummary mirrors mcp.ToolMeta plus the per-build enabled state
// pulled from the registry. The widget renders one toggle per row using
// `Enabled`; flipping it calls SetMCPToolEnabled which round-trips the
// change to disk and restarts running claude sessions so tools/list
// re-issues with the new set.
type MCPToolSummary struct {
	ID          string `json:"id"`
	Service     string `json:"service"`
	Label       string `json:"label"`
	Description string `json:"description"`
	Category    string `json:"category"`
	Priority    int    `json:"priority"`
	Enabled     bool   `json:"enabled"`
	// TokenCost is a per-spawn estimate of how many context tokens this
	// tool's schema adds to Claude Code's system prompt every message.
	// Computed once by mcp.Gateway.MeasureToolCosts via real
	// JSON-Schema serialisation (bytes / 4), then cached on the
	// Service so successive ListMCPTools calls are free.
	TokenCost int `json:"tokenCost"`
}

// ListMCPTools returns the curated catalog for one service merged with
// the current per-tool disable flags from the registry plus a cached
// token-cost estimate per tool. Sort order is stable across calls so
// the widget can render without re-sorting.
func (s *Service) ListMCPTools(ctx context.Context, service domain.MCPService) ([]MCPToolSummary, error) {
	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return nil, err
	}
	disabled := map[string]bool{}
	for _, id := range reg.DisabledMCPTools {
		disabled[id] = true
	}
	costs := s.mcpToolCosts()
	catalog := mcp.ToolsForService(service)
	out := make([]MCPToolSummary, 0, len(catalog))
	for _, t := range catalog {
		out = append(out, MCPToolSummary{
			ID:          t.ID,
			Service:     string(t.Service),
			Label:       t.Label,
			Description: t.Description,
			Category:    t.Category,
			Priority:    int(t.Priority),
			Enabled:     !disabled[t.ID],
			TokenCost:   costs[t.ID],
		})
	}
	return out, nil
}

// mcpToolCosts lazily computes per-tool token estimates once per process
// and caches the result. Building the gateway + serialising tools/list
// is cheap (~tens of ms) but doing it on every Settings open would be
// wasteful — schemas don't change between Sparkle builds.
//
// The measurement gateway is wired with stub stores for GitLab and
// Bitwarden so those tools register and contribute their schema bytes
// to the catalog. Production `mcp serve` wires the real instances
// (`gw.GitLabInstances`, `gw.BWSession`) from cmd_mcp.go; the early
// `if g.GitLabInstances == nil { return }` guard inside
// `registerGitLabTools` would otherwise skip the whole connector when
// measuring, leaving the widget's tool-cost column showing 0 across
// every GitLab row.
func (s *Service) mcpToolCosts() map[string]int {
	s.mcpToolCostsOnce.Do(func() {
		gw := mcp.New(s.Registry, s.MCPSecrets, "internal")
		// Throw-away store paths under the OS temp dir — measurement
		// only reads `List` (which returns an empty slice on a missing
		// file) and never writes. The constructor is non-nil-safe so
		// `registerGitLabTools` walks past its nil-check.
		gw.GitLabInstances = mcp.NewGitLabInstanceStore(
			filepath.Join(os.TempDir(), "claude-bar-measure-gitlab.json"),
		)
		gw.BWSession = mcp.NewBitwardenSession(time.Minute)
		s.mcpToolCostsCache = gw.MeasureToolCosts()
	})
	return s.mcpToolCostsCache
}

// SetMCPToolEnabled adds or removes one tool ID from the registry-wide
// `DisabledMCPTools` slice. The slice stays sorted + de-duplicated so
// JSON encoding is stable across writes and a grep on the registry file
// reads cleanly. Unknown tool IDs are accepted (no catalog cross-check)
// because the catalog can lag a Sparkle update — we'd rather silently
// honour a stored disable than reject the write.
func (s *Service) SetMCPToolEnabled(ctx context.Context, toolID string, enabled bool) error {
	if err := s.Lock.Acquire(ctx); err != nil {
		return err
	}
	defer s.Lock.Release()

	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return err
	}
	// Recompute the slice — small set, simpler than splicing.
	present := map[string]bool{}
	for _, id := range reg.DisabledMCPTools {
		present[id] = true
	}
	if enabled {
		delete(present, toolID)
	} else {
		present[toolID] = true
	}
	out := make([]string, 0, len(present))
	for id := range present {
		out = append(out, id)
	}
	sort.Strings(out)
	if len(out) == 0 {
		reg.DisabledMCPTools = nil
	} else {
		reg.DisabledMCPTools = out
	}
	return s.Registry.Save(ctx, reg)
}

// SetMCPConnectorEnabled flips the Enabled flag on an existing connector
// without touching the stored secret. Lets the UI temporarily silence a
// provider's tools (resolver returns ErrConnectorDisabled) while keeping the
// Keychain payload for a quick re-enable. Returns an error when no metadata
// exists for that service — callers should Connect first.
func (s *Service) SetMCPConnectorEnabled(ctx context.Context, accountNum int, svc domain.MCPService, enabled bool) error {
	if err := s.Lock.Acquire(ctx); err != nil {
		return err
	}
	defer s.Lock.Release()

	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return err
	}
	if accountNum == 0 {
		if reg.SharedMCPConnectors == nil {
			return fmt.Errorf("no shared connector for %s", svc)
		}
		meta, ok := reg.SharedMCPConnectors[svc]
		if !ok || meta == nil {
			return fmt.Errorf("no shared connector for %s", svc)
		}
		meta.Enabled = enabled
		return s.Registry.Save(ctx, reg)
	}
	acc, ok := reg.Accounts[accountNum]
	if !ok {
		return fmt.Errorf("account %d not found", accountNum)
	}
	meta, ok := acc.MCPConnectors[svc]
	if !ok || meta == nil {
		return fmt.Errorf("no connector for %s on account %d", svc, accountNum)
	}
	meta.Enabled = enabled
	return s.Registry.Save(ctx, reg)
}

// MarkMCPNeedsReauth flags a connector as needing re-authorization without
// touching the stored secret. Useful when a tool call sees auth-expired error.
func (s *Service) MarkMCPNeedsReauth(ctx context.Context, accountNum int, svc domain.MCPService) error {
	if err := s.Lock.Acquire(ctx); err != nil {
		return err
	}
	defer s.Lock.Release()

	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return err
	}
	metas := reg.SharedMCPConnectors
	if accountNum != 0 {
		acc, ok := reg.Accounts[accountNum]
		if !ok {
			return nil
		}
		metas = acc.MCPConnectors
	}
	if meta, ok := metas[svc]; ok && meta != nil {
		meta.NeedsReauth = true
		return s.Registry.Save(ctx, reg)
	}
	return nil
}
