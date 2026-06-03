package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/usecase"
	"github.com/soi/claude-swap-widget/backend/internal/usecase/netbird"
)

// runNetbird dispatches `csw netbird <config|overview|peers|grant|revoke|setup-key|peer|group>`.
func runNetbird(ctx context.Context, svc *usecase.Service, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw netbird <config|overview|peers|grant|revoke|setup-key|peer|group> ...")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "config":
		return runNetbirdConfig(ctx, svc, rest)
	case "overview":
		return runNetbirdOverview(ctx, svc, rest)
	case "peers":
		return runNetbirdPeers(ctx, svc, rest)
	case "grant":
		return runNetbirdGrant(ctx, svc, rest)
	case "revoke":
		return runNetbirdRevoke(ctx, svc, rest)
	case "setup-key":
		return runNetbirdSetupKey(ctx, svc, rest)
	case "peer":
		return runNetbirdPeer(ctx, svc, rest)
	case "group":
		return runNetbirdGroup(ctx, svc, rest)
	default:
		return fmt.Errorf("unknown netbird subcommand: %s", sub)
	}
}

// netbirdClient loads the saved credential and builds an API client.
func netbirdClient(ctx context.Context, svc *usecase.Service) (*netbird.Client, error) {
	cfg, err := netbird.LoadConfig(ctx, svc.MCPSecrets)
	if err != nil {
		return nil, err
	}
	return netbird.NewClient(cfg, nil), nil
}

// runNetbirdConfig handles `config set` and `config show`.
func runNetbirdConfig(ctx context.Context, svc *usecase.Service, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw netbird config <set|show>")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "set":
		fs := flag.NewFlagSet("set", flag.ExitOnError)
		baseURL := fs.String("base-url", "", "NetBird API base URL (default https://netbird.evselab.com/api)")
		token := fs.String("token", "", "PAT/service-user token, or - to read from stdin")
		asJSON := fs.Bool("json", false, "machine-readable output")
		_ = fs.Parse(rest)
		tok := *token
		if tok == "-" {
			b, err := io.ReadAll(os.Stdin)
			if err != nil {
				return err
			}
			tok = strings.TrimSpace(string(b))
		}
		if tok == "" {
			return errors.New("--token is required (use --token=- to read from stdin)")
		}
		if err := netbird.SaveConfig(ctx, svc.MCPSecrets, netbird.Config{BaseURL: *baseURL, Token: tok}); err != nil {
			return err
		}
		// Verify connectivity so a bad token/URL fails loudly at save time.
		cfg, _ := netbird.LoadConfig(ctx, svc.MCPSecrets)
		if _, err := netbird.NewClient(cfg, nil).ListPeers(ctx); err != nil {
			return fmt.Errorf("saved, but verify failed: %w", err)
		}
		return emit(*asJSON, map[string]any{"configured": true, "baseURL": cfg.BaseURL})
	case "show":
		fs := flag.NewFlagSet("show", flag.ExitOnError)
		asJSON := fs.Bool("json", false, "machine-readable output")
		_ = fs.Parse(rest)
		cfg, err := netbird.LoadConfig(ctx, svc.MCPSecrets)
		if errors.Is(err, netbird.ErrNotConfigured) {
			return emit(*asJSON, map[string]any{"configured": false, "baseURL": netbird.DefaultBaseURL})
		}
		if err != nil {
			return err
		}
		// Never emit the token.
		return emit(*asJSON, map[string]any{"configured": true, "baseURL": cfg.BaseURL})
	default:
		return fmt.Errorf("unknown config subcommand: %s", sub)
	}
}

func runNetbirdOverview(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("overview", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)
	c, err := netbirdClient(ctx, svc)
	if err != nil {
		return err
	}
	ov, err := netbird.BuildOverview(ctx, c)
	if err != nil {
		return err
	}
	return emit(*asJSON, ov)
}

func runNetbirdPeers(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("peers", flag.ExitOnError)
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)
	c, err := netbirdClient(ctx, svc)
	if err != nil {
		return err
	}
	peers, err := c.ListPeers(ctx)
	if err != nil {
		return err
	}
	return emit(*asJSON, peers)
}

// runNetbirdGrant creates a full-access policy from a dev group to a server
// group (matrix cell ON). Both groups are created if missing. Idempotent: if a
// matching grant already exists it returns that policy.
func runNetbirdGrant(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("grant", flag.ExitOnError)
	srcName := fs.String("src-group", "", "source group name (e.g. dev-an)")
	dstName := fs.String("dst-group", "", "destination group name (e.g. srv-api)")
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)
	if *srcName == "" || *dstName == "" {
		return errors.New("--src-group and --dst-group are required")
	}
	c, err := netbirdClient(ctx, svc)
	if err != nil {
		return err
	}
	ov, err := netbird.BuildOverview(ctx, c)
	if err != nil {
		return err
	}
	if id := ov.FindEdgePolicy(*srcName, *dstName); id != "" {
		return emit(*asJSON, map[string]any{"policyId": id, "created": false})
	}
	src, err := c.EnsureGroup(ctx, *srcName)
	if err != nil {
		return err
	}
	dst, err := c.EnsureGroup(ctx, *dstName)
	if err != nil {
		return err
	}
	pol, err := c.GrantAccess(ctx, src.ID, dst.ID, netbird.PolicyName(*srcName, *dstName))
	if err != nil {
		return err
	}
	return emit(*asJSON, map[string]any{"policyId": pol.ID, "created": true})
}

func runNetbirdRevoke(ctx context.Context, svc *usecase.Service, args []string) error {
	fs := flag.NewFlagSet("revoke", flag.ExitOnError)
	policyID := fs.String("policy", "", "policy ID to delete")
	asJSON := fs.Bool("json", false, "machine-readable output")
	_ = fs.Parse(args)
	if *policyID == "" {
		return errors.New("--policy is required")
	}
	c, err := netbirdClient(ctx, svc)
	if err != nil {
		return err
	}
	if err := c.DeletePolicy(ctx, *policyID); err != nil {
		return err
	}
	return emit(*asJSON, map[string]any{"deleted": true})
}

// runNetbirdSetupKey handles `setup-key <create|list|revoke>`.
func runNetbirdSetupKey(ctx context.Context, svc *usecase.Service, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw netbird setup-key <create|list|revoke> ...")
	}
	sub, rest := args[0], args[1:]
	c, err := netbirdClient(ctx, svc)
	if err != nil {
		return err
	}
	switch sub {
	case "create":
		fs := flag.NewFlagSet("create", flag.ExitOnError)
		name := fs.String("name", "dev-enroll", "setup key name")
		group := fs.String("group", netbird.GroupPending, "auto-assign group name for new machines")
		expiresDays := fs.Int("expires-days", 7, "expiry in days")
		usageLimit := fs.Int("usage-limit", 0, "max uses (0 = unlimited)")
		asJSON := fs.Bool("json", false, "machine-readable output")
		_ = fs.Parse(rest)
		g, err := c.EnsureGroup(ctx, *group)
		if err != nil {
			return err
		}
		key, err := c.CreateSetupKey(ctx, *name, []string{g.ID}, *expiresDays*86400, *usageLimit)
		if err != nil {
			return err
		}
		return emit(*asJSON, key)
	case "list":
		fs := flag.NewFlagSet("list", flag.ExitOnError)
		asJSON := fs.Bool("json", false, "machine-readable output")
		_ = fs.Parse(rest)
		keys, err := c.ListSetupKeys(ctx)
		if err != nil {
			return err
		}
		// Normalize the polymorphic id to a string so the Swift client gets a
		// stable shape (NetBird emits the key id as a number or a string).
		type keyInfo struct {
			ID         string `json:"id"`
			Name       string `json:"name"`
			State      string `json:"state"`
			Valid      bool   `json:"valid"`
			Revoked    bool   `json:"revoked"`
			UsedTimes  int    `json:"usedTimes"`
			UsageLimit int    `json:"usageLimit"`
			Expires    string `json:"expires"`
			Ephemeral  bool   `json:"ephemeral"`
			Type       string `json:"type"`
		}
		out := make([]keyInfo, 0, len(keys))
		for _, k := range keys {
			out = append(out, keyInfo{
				ID: k.IDString(), Name: k.Name, State: k.State, Valid: k.Valid,
				Revoked: k.Revoked, UsedTimes: k.UsedTimes, UsageLimit: k.UsageLimit,
				Expires: k.Expires, Ephemeral: k.Ephemeral, Type: k.Type,
			})
		}
		return emit(*asJSON, out)
	case "revoke":
		fs := flag.NewFlagSet("revoke", flag.ExitOnError)
		id := fs.String("id", "", "setup key ID")
		asJSON := fs.Bool("json", false, "machine-readable output")
		_ = fs.Parse(rest)
		if *id == "" {
			return errors.New("--id is required")
		}
		if err := c.DeleteSetupKey(ctx, *id); err != nil {
			return err
		}
		return emit(*asJSON, map[string]any{"revoked": true})
	default:
		return fmt.Errorf("unknown setup-key subcommand: %s", sub)
	}
}

// runNetbirdPeer handles `peer <delete|rename|assign|remove>`.
func runNetbirdPeer(ctx context.Context, svc *usecase.Service, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw netbird peer <delete|rename|assign|remove> ...")
	}
	sub, rest := args[0], args[1:]
	c, err := netbirdClient(ctx, svc)
	if err != nil {
		return err
	}
	switch sub {
	case "delete":
		fs := flag.NewFlagSet("delete", flag.ExitOnError)
		id := fs.String("id", "", "peer ID")
		asJSON := fs.Bool("json", false, "machine-readable output")
		_ = fs.Parse(rest)
		if *id == "" {
			return errors.New("--id is required")
		}
		if err := c.DeletePeer(ctx, *id); err != nil {
			return err
		}
		return emit(*asJSON, map[string]any{"deleted": true})
	case "rename":
		fs := flag.NewFlagSet("rename", flag.ExitOnError)
		id := fs.String("id", "", "peer ID")
		name := fs.String("name", "", "new name")
		asJSON := fs.Bool("json", false, "machine-readable output")
		_ = fs.Parse(rest)
		if *id == "" || *name == "" {
			return errors.New("--id and --name are required")
		}
		peers, err := c.ListPeers(ctx)
		if err != nil {
			return err
		}
		for _, p := range peers {
			if p.ID == *id {
				if _, err := c.RenamePeer(ctx, p, *name); err != nil {
					return err
				}
				return emit(*asJSON, map[string]any{"renamed": true, "name": *name})
			}
		}
		return fmt.Errorf("peer not found: %s", *id)
	case "assign":
		fs := flag.NewFlagSet("assign", flag.ExitOnError)
		id := fs.String("id", "", "peer ID")
		group := fs.String("group", "", "target group name (e.g. dev-an)")
		asJSON := fs.Bool("json", false, "machine-readable output")
		_ = fs.Parse(rest)
		if *id == "" || *group == "" {
			return errors.New("--id and --group are required")
		}
		// Add to the target group, then drop from the pending isolation group.
		if _, err := c.AssignPeerToGroup(ctx, *id, *group); err != nil {
			return err
		}
		groups, err := c.ListGroups(ctx)
		if err != nil {
			return err
		}
		for _, g := range groups {
			if g.Name == netbird.GroupPending {
				if _, err := c.RemovePeerFromGroup(ctx, g, *id); err != nil {
					return err
				}
			}
		}
		return emit(*asJSON, map[string]any{"assigned": true, "group": *group})
	case "remove":
		fs := flag.NewFlagSet("remove", flag.ExitOnError)
		id := fs.String("id", "", "peer ID")
		group := fs.String("group", "", "group name to remove the peer from")
		asJSON := fs.Bool("json", false, "machine-readable output")
		_ = fs.Parse(rest)
		if *id == "" || *group == "" {
			return errors.New("--id and --group are required")
		}
		groups, err := c.ListGroups(ctx)
		if err != nil {
			return err
		}
		for _, g := range groups {
			if g.Name == *group {
				if _, err := c.RemovePeerFromGroup(ctx, g, *id); err != nil {
					return err
				}
				return emit(*asJSON, map[string]any{"removed": true, "group": *group})
			}
		}
		return fmt.Errorf("group not found: %s", *group)
	default:
		return fmt.Errorf("unknown peer subcommand: %s", sub)
	}
}

// runNetbirdGroup handles `group <create|rename|delete>`.
func runNetbirdGroup(ctx context.Context, svc *usecase.Service, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw netbird group <create|rename|delete> ...")
	}
	sub, rest := args[0], args[1:]
	c, err := netbirdClient(ctx, svc)
	if err != nil {
		return err
	}
	switch sub {
	case "create":
		fs := flag.NewFlagSet("create", flag.ExitOnError)
		name := fs.String("name", "", "group name")
		asJSON := fs.Bool("json", false, "machine-readable output")
		_ = fs.Parse(rest)
		if strings.TrimSpace(*name) == "" {
			return errors.New("--name is required")
		}
		// EnsureGroup keeps create idempotent: reuse an existing group with the
		// same name instead of producing two groups the matrix (keyed by name)
		// couldn't tell apart.
		g, err := c.EnsureGroup(ctx, *name)
		if err != nil {
			return err
		}
		return emit(*asJSON, map[string]any{"id": g.ID, "name": g.Name})
	case "rename":
		fs := flag.NewFlagSet("rename", flag.ExitOnError)
		id := fs.String("id", "", "group ID")
		name := fs.String("name", "", "new group name")
		asJSON := fs.Bool("json", false, "machine-readable output")
		_ = fs.Parse(rest)
		if *id == "" || *name == "" {
			return errors.New("--id and --name are required")
		}
		groups, err := c.ListGroups(ctx)
		if err != nil {
			return err
		}
		for _, g := range groups {
			if g.ID == *id {
				ids := make([]string, 0, len(g.Peers))
				for _, p := range g.Peers {
					ids = append(ids, p.ID)
				}
				if _, err := c.UpdateGroup(ctx, *id, *name, ids); err != nil {
					return err
				}
				return emit(*asJSON, map[string]any{"renamed": true, "name": *name})
			}
		}
		return fmt.Errorf("group not found: %s", *id)
	case "delete":
		fs := flag.NewFlagSet("delete", flag.ExitOnError)
		id := fs.String("id", "", "group ID")
		asJSON := fs.Bool("json", false, "machine-readable output")
		_ = fs.Parse(rest)
		if *id == "" {
			return errors.New("--id is required")
		}
		// NetBird blocks deletion while the group is still referenced; that
		// error propagates so the UI can show what still uses it.
		if err := c.DeleteGroup(ctx, *id); err != nil {
			return err
		}
		return emit(*asJSON, map[string]any{"deleted": true})
	default:
		return fmt.Errorf("unknown group subcommand: %s", sub)
	}
}
