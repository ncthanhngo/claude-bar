package netbird

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Client is a thin NetBird management API client. All calls send a Bearer
// token and JSON. It never logs the token.
type Client struct {
	HTTP    *http.Client
	BaseURL string
	Token   string
}

// NewClient builds a client from config, defaulting the HTTP client.
func NewClient(cfg Config, hc *http.Client) *Client {
	if hc == nil {
		hc = &http.Client{Timeout: 20 * time.Second}
	}
	return &Client{HTTP: hc, BaseURL: normalizeBaseURL(cfg.BaseURL), Token: cfg.Token}
}

// do performs a request and decodes the JSON response into out (may be nil).
// Non-2xx responses become errors carrying the response body for diagnosis.
func (c *Client) do(ctx context.Context, method, path string, body, out any) error {
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Token "+c.Token)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg := strings.TrimSpace(string(data))
		if len(msg) > 400 {
			msg = msg[:400]
		}
		return fmt.Errorf("netbird %s %s: %s: %s", method, path, resp.Status, msg)
	}
	if out != nil && len(data) > 0 {
		if err := json.Unmarshal(data, out); err != nil {
			return fmt.Errorf("decode %s %s: %w", method, path, err)
		}
	}
	return nil
}

// ListPeers returns all peers (never nil).
func (c *Client) ListPeers(ctx context.Context) ([]Peer, error) {
	out := []Peer{}
	if err := c.do(ctx, http.MethodGet, "/peers", nil, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// ListGroups returns all groups (never nil).
func (c *Client) ListGroups(ctx context.Context) ([]Group, error) {
	out := []Group{}
	if err := c.do(ctx, http.MethodGet, "/groups", nil, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// ListPolicies returns all policies (never nil).
func (c *Client) ListPolicies(ctx context.Context) ([]Policy, error) {
	out := []Policy{}
	if err := c.do(ctx, http.MethodGet, "/policies", nil, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// DeletePeer removes a peer (used to reject a pending machine).
func (c *Client) DeletePeer(ctx context.Context, id string) error {
	return c.do(ctx, http.MethodDelete, "/peers/"+id, nil, nil)
}

type peerUpdateRequest struct {
	Name                   string `json:"name"`
	SSHEnabled             bool   `json:"ssh_enabled"`
	LoginExpirationEnabled bool   `json:"login_expiration_enabled"`
}

// RenamePeer changes a peer's display name. It echoes the peer's current
// ssh_enabled / login_expiration_enabled back so PUT doesn't reset them.
func (c *Client) RenamePeer(ctx context.Context, p Peer, newName string) (Peer, error) {
	req := peerUpdateRequest{
		Name:                   newName,
		SSHEnabled:             p.SSHEnabled,
		LoginExpirationEnabled: p.LoginExpirationEnabled,
	}
	var out Peer
	err := c.do(ctx, http.MethodPut, "/peers/"+p.ID, req, &out)
	return out, err
}

// DeletePolicy removes a policy (used to revoke access).
func (c *Client) DeletePolicy(ctx context.Context, id string) error {
	return c.do(ctx, http.MethodDelete, "/policies/"+id, nil, nil)
}

// --- group create/update ---

type groupRequest struct {
	Name  string   `json:"name"`
	Peers []string `json:"peers"`
}

// CreateGroup makes a new group with the given peer IDs.
func (c *Client) CreateGroup(ctx context.Context, name string, peerIDs []string) (Group, error) {
	if peerIDs == nil {
		peerIDs = []string{}
	}
	var out Group
	err := c.do(ctx, http.MethodPost, "/groups", groupRequest{Name: name, Peers: peerIDs}, &out)
	return out, err
}

// UpdateGroup replaces a group's peer membership.
func (c *Client) UpdateGroup(ctx context.Context, id, name string, peerIDs []string) (Group, error) {
	if peerIDs == nil {
		peerIDs = []string{}
	}
	var out Group
	err := c.do(ctx, http.MethodPut, "/groups/"+id, groupRequest{Name: name, Peers: peerIDs}, &out)
	return out, err
}

// DeleteGroup removes a group. NetBird rejects the call (4xx) while the group is
// still referenced by a policy, route, setup-key or DNS setting; that error is
// surfaced verbatim via do() so the caller can tell the user what still
// references it instead of silently unlinking anything.
func (c *Client) DeleteGroup(ctx context.Context, id string) error {
	return c.do(ctx, http.MethodDelete, "/groups/"+id, nil, nil)
}

// EnsureGroup returns the existing group with name, or creates an empty one.
func (c *Client) EnsureGroup(ctx context.Context, name string) (Group, error) {
	groups, err := c.ListGroups(ctx)
	if err != nil {
		return Group{}, err
	}
	for _, g := range groups {
		if g.Name == name {
			return g, nil
		}
	}
	return c.CreateGroup(ctx, name, nil)
}

// AssignPeerToGroup adds peerID to the named group (creating it if needed) and
// removes the peer from every dev-pending / other prefixed group it shouldn't
// stay in is left to callers; this only adds membership.
func (c *Client) AssignPeerToGroup(ctx context.Context, peerID, groupName string) (Group, error) {
	g, err := c.EnsureGroup(ctx, groupName)
	if err != nil {
		return Group{}, err
	}
	ids := peerIDsOf(g)
	if !contains(ids, peerID) {
		ids = append(ids, peerID)
	}
	return c.UpdateGroup(ctx, g.ID, g.Name, ids)
}

// RemovePeerFromGroup drops peerID from group g.
func (c *Client) RemovePeerFromGroup(ctx context.Context, g Group, peerID string) (Group, error) {
	ids := []string{}
	for _, p := range g.Peers {
		if p.ID != peerID {
			ids = append(ids, p.ID)
		}
	}
	return c.UpdateGroup(ctx, g.ID, g.Name, ids)
}

// --- policy create ---

type ruleRequest struct {
	Name          string   `json:"name"`
	Enabled       bool     `json:"enabled"`
	Action        string   `json:"action"`
	Bidirectional bool     `json:"bidirectional"`
	Protocol      string   `json:"protocol"`
	Sources       []string `json:"sources"`
	Destinations  []string `json:"destinations"`
}

type policyRequest struct {
	Name        string        `json:"name"`
	Description string        `json:"description"`
	Enabled     bool          `json:"enabled"`
	Rules       []ruleRequest `json:"rules"`
}

// GrantAccess creates a full-access (protocol=all, bidirectional) policy from
// the source group to the destination group, named by convention so the panel
// can recognise it as app-managed. Returns the created policy.
func (c *Client) GrantAccess(ctx context.Context, srcGroupID, dstGroupID, name string) (Policy, error) {
	req := policyRequest{
		Name:    name,
		Enabled: true,
		Rules: []ruleRequest{{
			Name:          name,
			Enabled:       true,
			Action:        "accept",
			Bidirectional: true,
			Protocol:      "all",
			Sources:       []string{srcGroupID},
			Destinations:  []string{dstGroupID},
		}},
	}
	var out Policy
	err := c.do(ctx, http.MethodPost, "/policies", req, &out)
	return out, err
}

// --- setup keys ---

type setupKeyRequest struct {
	Name       string   `json:"name"`
	Type       string   `json:"type"`
	ExpiresIn  int      `json:"expires_in"`
	AutoGroups []string `json:"auto_groups"`
	UsageLimit int      `json:"usage_limit"`
	Ephemeral  bool     `json:"ephemeral"`
}

// CreateSetupKey makes an enrollment key that auto-assigns new machines into
// autoGroups. expiresIn is seconds. usageLimit caps how many machines may
// enroll with it: 1 produces a true single-use "one-off" key that NetBird
// invalidates after the first peer; >1 (or 0 = unlimited) produces a "reusable"
// key. Deriving the type from the limit keeps single-use keys server-enforced
// and correctly labelled instead of a "reusable" key that merely caps at 1.
func (c *Client) CreateSetupKey(ctx context.Context, name string, autoGroups []string, expiresIn, usageLimit int) (SetupKey, error) {
	if autoGroups == nil {
		autoGroups = []string{}
	}
	keyType := "reusable"
	if usageLimit == 1 {
		keyType = "one-off"
	}
	req := setupKeyRequest{
		Name:       name,
		Type:       keyType,
		ExpiresIn:  expiresIn,
		AutoGroups: autoGroups,
		UsageLimit: usageLimit,
	}
	var out SetupKey
	err := c.do(ctx, http.MethodPost, "/setup-keys", req, &out)
	return out, err
}

// ListSetupKeys returns all setup keys (never nil). NetBird only returns the
// plaintext key from create, so listed keys carry metadata (state / usage /
// revoked) but no secret.
func (c *Client) ListSetupKeys(ctx context.Context) ([]SetupKey, error) {
	out := []SetupKey{}
	if err := c.do(ctx, http.MethodGet, "/setup-keys", nil, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// DeleteSetupKey removes a setup key so it can no longer enroll machines.
func (c *Client) DeleteSetupKey(ctx context.Context, id string) error {
	return c.do(ctx, http.MethodDelete, "/setup-keys/"+id, nil, nil)
}

// --- helpers ---

func peerIDsOf(g Group) []string {
	ids := make([]string, 0, len(g.Peers))
	for _, p := range g.Peers {
		ids = append(ids, p.ID)
	}
	return ids
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}
