// Package netbird talks to a self-hosted NetBird management API. It powers the
// Workspace Netbird panel: list peers/groups/policies, grant/revoke access by
// toggling policies, generate setup keys, and approve/reject pending machines.
//
// JSON field names below match the NetBird REST API verbatim
// (https://docs.netbird.io/api). Slices returned to the Swift client are
// always non-nil so a nil slice never decodes to JSON null and breaks a
// non-optional Swift array.
package netbird

import (
	"encoding/json"
	"strings"
)

// GroupRef is the {id,name} shape NetBird embeds inside peers and policy rules.
type GroupRef struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// Peer is one machine in the mesh (server or dev laptop).
type Peer struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	IP         string     `json:"ip"`
	Connected  bool       `json:"connected"`
	LastSeen   string     `json:"last_seen"`
	OS         string     `json:"os"`
	Version    string     `json:"version"`
	Hostname   string     `json:"hostname"`
	DNSLabel   string     `json:"dns_label"`
	SSHEnabled bool       `json:"ssh_enabled"`
	UserID     string     `json:"user_id"`
	Groups     []GroupRef `json:"groups"`

	// LoginExpirationEnabled is echoed back unchanged when renaming a peer so
	// a rename (PUT /peers) doesn't silently flip it off.
	LoginExpirationEnabled bool `json:"login_expiration_enabled"`
}

// Group is a NetBird group. Peers holds the member peers as {id,name}.
type Group struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	PeersCount int        `json:"peers_count"`
	Peers      []GroupRef `json:"peers"`
}

// PolicyRule is one rule inside a policy. In responses sources/destinations are
// expanded group objects; in create requests they are plain group-ID strings,
// so request building uses a separate type (see ruleRequest in client.go).
type PolicyRule struct {
	ID            string     `json:"id"`
	Name          string     `json:"name"`
	Enabled       bool       `json:"enabled"`
	Action        string     `json:"action"`
	Bidirectional bool       `json:"bidirectional"`
	Protocol      string     `json:"protocol"`
	Ports         []string   `json:"ports"`
	Sources       []GroupRef `json:"sources"`
	Destinations  []GroupRef `json:"destinations"`
}

// Policy is a NetBird access-control policy (one or more rules).
type Policy struct {
	ID          string       `json:"id"`
	Name        string       `json:"name"`
	Description string       `json:"description"`
	Enabled     bool         `json:"enabled"`
	Rules       []PolicyRule `json:"rules"`
}

// SetupKey is a pre-auth enrollment key. NetBird returns `id` as a JSON number
// (unlike peers/groups/policies whose ids are strings), so it is kept as raw
// JSON to tolerate both number and string forms across versions.
type SetupKey struct {
	ID         json.RawMessage `json:"id,omitempty"`
	Name       string   `json:"name"`
	Key        string   `json:"key"`
	Type       string   `json:"type"`
	State      string   `json:"state"`
	Valid      bool     `json:"valid"`
	Revoked    bool     `json:"revoked"`
	UsedTimes  int      `json:"used_times"`
	Expires    string   `json:"expires"`
	UsageLimit int      `json:"usage_limit"`
	Ephemeral  bool     `json:"ephemeral"`
	AutoGroups []string `json:"auto_groups"`
}

// IDString returns the setup-key id as a string regardless of whether NetBird
// encoded it as a JSON number or a JSON string (it varies across versions).
func (k SetupKey) IDString() string {
	return strings.Trim(strings.TrimSpace(string(k.ID)), `"`)
}

// AccessEdge is one app-managed grant: a policy whose name follows the
// `<srcGroup>__<dstGroup>` convention, linking a dev group to a server group.
type AccessEdge struct {
	PolicyID    string `json:"policyId"`
	SourceGroup string `json:"sourceGroup"`
	DestGroup   string `json:"destGroup"`
}

// Overview is the single-call view model for the Workspace panel. Servers and
// Devs are peers whose group membership matches the naming convention; Pending
// is peers in the dev-pending isolation group; Access lists app-managed edges;
// External lists policies that don't match the convention (shown read-only).
type Overview struct {
	Peers    []Peer       `json:"peers"`
	Groups   []Group      `json:"groups"`
	Policies []Policy     `json:"policies"`
	Access   []AccessEdge `json:"access"`
	External []Policy     `json:"external"`
}
