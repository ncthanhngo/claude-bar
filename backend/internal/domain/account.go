// Package domain holds pure entities and value objects. No I/O, no framework.
package domain

import "time"

// Account is a managed Claude Code account profile.
//
// Identity = (Email, OrganizationUUID). Two rows with same email but different
// orgs are distinct profiles (personal vs work workspace).
type Account struct {
	Number           int       `json:"number"`
	Email            string    `json:"email"`
	OrganizationName string    `json:"organizationName,omitempty"`
	OrganizationUUID string    `json:"organizationUuid,omitempty"`
	Nickname         string    `json:"nickname,omitempty"`
	CreatedAt        time.Time `json:"createdAt"`

	// MCPConnectors is non-secret per-account metadata for local MCP
	// connectors. Tokens live in the macOS Keychain under
	// "claude-bar-mcp:<number>:<service>".
	MCPConnectors AccountConnectors `json:"mcpConnectors,omitempty"`
}

// DisplayName returns nickname if set, otherwise email.
func (a Account) DisplayName() string {
	if a.Nickname != "" {
		return a.Nickname
	}
	return a.Email
}

// IdentityKey is the deduplication key.
func (a Account) IdentityKey() string {
	return a.Email + "|" + a.OrganizationUUID
}

// Registry is the on-disk state for all managed accounts.
type Registry struct {
	Version             int               `json:"version"`
	ActiveAccountNumber int               `json:"activeAccountNumber"`
	Sequence            []int             `json:"sequence"`
	Accounts            map[int]*Account  `json:"accounts"`
	SharedMCPConnectors AccountConnectors `json:"sharedMcpConnectors,omitempty"`
	LastUpdated         time.Time         `json:"lastUpdated"`
}

// NewRegistry returns an empty registry at the current schema version.
func NewRegistry() *Registry {
	return &Registry{
		Version:  1,
		Sequence: []int{},
		Accounts: map[int]*Account{},
	}
}

// NextAccountNumber returns the next free integer ID (1-based).
func (r *Registry) NextAccountNumber() int {
	max := 0
	for n := range r.Accounts {
		if n > max {
			max = n
		}
	}
	return max + 1
}

// FindByIdentity returns the account number matching (email, orgUUID), or 0.
func (r *Registry) FindByIdentity(email, orgUUID string) int {
	for num, acc := range r.Accounts {
		if acc.Email == email && acc.OrganizationUUID == orgUUID {
			return num
		}
	}
	return 0
}
