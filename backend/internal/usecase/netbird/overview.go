package netbird

import "context"

// Naming convention — the whole Workspace panel relies on these prefixes so the
// matrix maps 1:1 to NetBird groups/policies without storing extra state.
const (
	GroupPrefixServer = "srv-"       // one group per server: srv-api, srv-db…
	GroupPrefixDev    = "dev-"       // one group per dev: dev-an, dev-binh…
	GroupPending      = "dev-pending" // isolation group for newly enrolled machines
	GroupAdmin        = "admin"       // the admin's own machine (reverse support)
	policySep         = "__"          // grant policy name = <srcGroup>__<dstGroup>
)

// PolicyName builds the canonical app-managed policy name for an edge.
func PolicyName(srcGroup, dstGroup string) string {
	return srcGroup + policySep + dstGroup
}

// BuildOverview fetches peers, groups and policies in three calls and derives
// the app's view model: which policies are app-managed grants (Access) versus
// external (left read-only). Servers/devs are not split here — the Swift panel
// classifies peers by group prefix — but the convention lives in this package.
func BuildOverview(ctx context.Context, c *Client) (Overview, error) {
	peers, err := c.ListPeers(ctx)
	if err != nil {
		return Overview{}, err
	}
	groups, err := c.ListGroups(ctx)
	if err != nil {
		return Overview{}, err
	}
	policies, err := c.ListPolicies(ctx)
	if err != nil {
		return Overview{}, err
	}

	access := []AccessEdge{}
	external := []Policy{}
	for _, p := range policies {
		edge, ok := classifyPolicy(p)
		if ok {
			access = append(access, edge)
		} else {
			external = append(external, p)
		}
	}

	return Overview{
		Peers:    peers,
		Groups:   groups,
		Policies: policies,
		Access:   access,
		External: external,
	}, nil
}

// classifyPolicy reports whether a policy is a simple group→group grant the
// matrix can represent: exactly one rule, one source group, one destination
// group. The policy NAME is intentionally NOT checked — that keeps the matrix
// in sync after a group rename (the name string would otherwise go stale) and
// surfaces externally-created simple policies too. Multi-rule / multi-group
// policies fall through to External and are shown read-only.
func classifyPolicy(p Policy) (AccessEdge, bool) {
	if len(p.Rules) != 1 {
		return AccessEdge{}, false
	}
	r := p.Rules[0]
	if len(r.Sources) != 1 || len(r.Destinations) != 1 {
		return AccessEdge{}, false
	}
	return AccessEdge{PolicyID: p.ID, SourceGroup: r.Sources[0].Name, DestGroup: r.Destinations[0].Name}, true
}

// FindEdgePolicy returns the policy ID granting src→dst, or "" if none.
func (o Overview) FindEdgePolicy(srcGroup, dstGroup string) string {
	for _, e := range o.Access {
		if e.SourceGroup == srcGroup && e.DestGroup == dstGroup {
			return e.PolicyID
		}
	}
	return ""
}

// GroupByName returns the group with the given name, or false.
func (o Overview) GroupByName(name string) (Group, bool) {
	for _, g := range o.Groups {
		if g.Name == name {
			return g, true
		}
	}
	return Group{}, false
}
