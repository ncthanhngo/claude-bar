package domain

import "time"

// MCPService is the canonical identifier for a connector backend.
type MCPService string

const (
	MCPServiceSlack     MCPService = "slack"
	MCPServiceClickUp   MCPService = "clickup"
	MCPServiceGDrive    MCPService = "gdrive"
	MCPServiceGitHub    MCPService = "github"
	MCPServiceBitwarden MCPService = "bitwarden"

	// MCPServiceNetbird is a Keychain credential slot only — NOT a Claude
	// Code tool connector. It is deliberately absent from AllMCPServices so
	// it never registers tools in the MCP gateway or appears in the generic
	// connectors UI. The Workspace Netbird panel reads/writes this slot
	// directly via the secret store (csw netbird config). Payload is JSON
	// {"baseURL":"…","token":"…"} stored under the shared account (0).
	MCPServiceNetbird MCPService = "netbird"
)

// AllMCPServices is the registration order used for UI and tools/list.
var AllMCPServices = []MCPService{
	MCPServiceSlack, MCPServiceClickUp, MCPServiceGDrive,
	MCPServiceGitHub, MCPServiceBitwarden,
}

// MCPConnector is non-secret metadata for one provider on one Claude Bar
// account. Tokens live in the Keychain, never in this struct.
type MCPConnector struct {
	Enabled      bool      `json:"enabled"`
	DisplayName  string    `json:"displayName,omitempty"`
	Account      string    `json:"account,omitempty"`
	Scopes       []string  `json:"scopes,omitempty"`
	ConnectedAt  time.Time `json:"connectedAt,omitempty"`
	LastVerified time.Time `json:"lastVerified,omitempty"`
	NeedsReauth  bool      `json:"needsReauth,omitempty"`
}

// AccountConnectors maps a service identifier to its metadata.
type AccountConnectors map[MCPService]*MCPConnector
