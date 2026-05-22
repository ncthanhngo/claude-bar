package mcp

import (
	"context"
	"net/http"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// Public helpers that let in-process callers (e.g. briefing orchestrator) reuse
// Gateway's credential resolution + HTTP client without depending on the MCP
// stdio tool surface.

// GoogleAccessToken returns a fresh OAuth access token for the active account's
// Google connector. Performs refresh if the cached token is expired.
func (g *Gateway) GoogleAccessToken(ctx context.Context) (string, error) {
	return g.googleAccess(ctx)
}

// ServiceToken returns the raw token payload for a non-OAuth service
// (ClickUp personal API key, Slack user token). Returns the typed errors
// from Resolver (ErrConnectorDisabled, ErrConnectorUnauthorized).
func (g *Gateway) ServiceToken(ctx context.Context, svc domain.MCPService) (string, error) {
	cc, err := g.Resolver.Resolve(ctx, svc)
	if err != nil {
		return "", err
	}
	return cc.Payload, nil
}

// HTTPClient returns the shared HTTP client used by all MCP tool handlers.
func (g *Gateway) HTTPClient() *http.Client { return g.HTTP }

// UserAgentString returns the User-Agent string the gateway uses.
func (g *Gateway) UserAgentString() string { return g.UserAgent }
