package mcp

import (
	"errors"
	"fmt"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
)

// toolErrorForResolve maps a Resolver error to a user-safe CallToolResult.
// The text must not reveal which other accounts have the connector.
func toolErrorForResolve(err error) *mcpgo.CallToolResult {
	switch {
	case errors.Is(err, ErrNoActiveAccount):
		return mcpgo.NewToolResultError("connector_unavailable: no active Claude Bar account")
	case errors.Is(err, ErrConnectorDisabled):
		return mcpgo.NewToolResultError("connector_disabled")
	case errors.Is(err, ErrConnectorUnauthorized):
		return mcpgo.NewToolResultError("connector_unavailable: not authorized")
	default:
		return mcpgo.NewToolResultError("connector_error: " + Redact(err.Error()))
	}
}

// toolErrorf returns a redacted error result.
func toolErrorf(format string, args ...any) *mcpgo.CallToolResult {
	return mcpgo.NewToolResultError(Redact(fmt.Sprintf(format, args...)))
}
