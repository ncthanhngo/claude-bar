package usecase

import (
	"context"
	"fmt"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
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
}

// MCPAccountSummary lists every supported service for one account, marking
// which are connected and which still need setup.
type MCPAccountSummary struct {
	AccountNumber int                   `json:"accountNumber"`
	DisplayName   string                `json:"displayName"`
	Active        bool                  `json:"active"`
	Connectors    []MCPConnectorSummary `json:"connectors"`
}

// ListMCPConnectors returns a summary for every account in the registry.
func (s *Service) ListMCPConnectors(ctx context.Context) ([]MCPAccountSummary, error) {
	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]MCPAccountSummary, 0, len(reg.Sequence))
	for _, num := range reg.Sequence {
		acc, ok := reg.Accounts[num]
		if !ok {
			continue
		}
		summary := MCPAccountSummary{
			AccountNumber: num,
			DisplayName:   acc.DisplayName(),
			Active:        reg.ActiveAccountNumber == num,
			Connectors:    make([]MCPConnectorSummary, 0, len(domain.AllMCPServices)),
		}
		for _, svc := range domain.AllMCPServices {
			row := MCPConnectorSummary{Service: svc}
			if meta, ok := acc.MCPConnectors[svc]; ok && meta != nil {
				row.Enabled = meta.Enabled
				row.DisplayName = meta.DisplayName
				row.Account = meta.Account
				row.NeedsReauth = meta.NeedsReauth
				row.ConnectedAt = meta.ConnectedAt
			}
			payload, err := s.MCPSecrets.Read(ctx, num, svc)
			if err != nil {
				return nil, fmt.Errorf("read mcp secret %s/%d: %w", svc, num, err)
			}
			row.HasSecret = payload != ""
			summary.Connectors = append(summary.Connectors, row)
		}
		out = append(out, summary)
	}
	return out, nil
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
	acc, ok := reg.Accounts[req.AccountNumber]
	if !ok {
		return fmt.Errorf("account %d not found", req.AccountNumber)
	}
	if err := s.MCPSecrets.Write(ctx, req.AccountNumber, req.Service, req.Payload); err != nil {
		return fmt.Errorf("write mcp secret: %w", err)
	}
	if acc.MCPConnectors == nil {
		acc.MCPConnectors = domain.AccountConnectors{}
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
	acc.MCPConnectors[req.Service] = meta
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
	acc, ok := reg.Accounts[accountNum]
	if !ok {
		return fmt.Errorf("account %d not found", accountNum)
	}
	if err := s.MCPSecrets.Delete(ctx, accountNum, svc); err != nil {
		return fmt.Errorf("delete mcp secret: %w", err)
	}
	if acc.MCPConnectors != nil {
		delete(acc.MCPConnectors, svc)
		if len(acc.MCPConnectors) == 0 {
			acc.MCPConnectors = nil
		}
	}
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
	acc, ok := reg.Accounts[accountNum]
	if !ok {
		return nil
	}
	if meta, ok := acc.MCPConnectors[svc]; ok && meta != nil {
		meta.NeedsReauth = true
		return s.Registry.Save(ctx, reg)
	}
	return nil
}
