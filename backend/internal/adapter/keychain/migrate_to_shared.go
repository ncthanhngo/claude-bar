package keychain

import (
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// MigrationOutcome reports what the one-shot MCP-to-shared canonicalisation
// did. Surfaced in Diagnostics so the user can see which per-account token
// won when two accounts had different credentials for the same service.
type MigrationOutcome struct {
	RanAt          time.Time          `json:"ranAt"`
	AlreadyDone    bool               `json:"alreadyDone"`
	ServiceResults []ServiceMigration `json:"serviceResults,omitempty"`
}

// ServiceMigration is the per-service outcome of canonicalisation.
type ServiceMigration struct {
	Service        domain.MCPService `json:"service"`
	Action         MigrationAction   `json:"action"`
	WinningAccount int               `json:"winningAccount,omitempty"`
	CandidateCount int               `json:"candidateCount"`
	Error          string            `json:"error,omitempty"`
}

// MigrationAction explains what happened for one service slot.
type MigrationAction string

const (
	// ActionNoOp means there were no per-account secrets to migrate.
	ActionNoOp MigrationAction = "noop"
	// ActionCanonicalised means a per-account secret was copied into the
	// shared slot (which was previously empty).
	ActionCanonicalised MigrationAction = "canonicalised"
	// ActionKeptShared means the shared slot already had a secret, so the
	// per-account candidate(s) were left in place for legacy rollback.
	ActionKeptShared MigrationAction = "kept-shared"
	// ActionFailed means the migration attempt errored. The error message is
	// in ServiceMigration.Error.
	ActionFailed MigrationAction = "failed"
)

// MigrateToShared canonicalises per-account MCP secrets under the shared
// account-key. Idempotent: a sentinel keychain entry tracks completion, so
// callers can invoke this on every boot.
//
// Strategy when multiple accounts hold a token for the same service:
//   - Pick the most recently connected account based on the registry's
//     `ConnectedAt` metadata.
//   - Tie-breaker is the lowest account number (stable ordering).
//
// Legacy per-account entries are NOT deleted — they stay in the keychain for
// two release cycles so users can roll the app back without re-authenticating.
//
// Sentinel-on-failure policy: if ANY service result is ActionFailed (e.g.
// keychain transiently locked), the sentinel is NOT written so the next boot
// retries. Successful services already wrote to the shared slot; the second
// pass will see those slots populated and report ActionKeptShared — that's
// the expected idempotent re-run path.
func MigrateToShared(ctx context.Context, store port.MCPSecretStore, reg *domain.Registry) (MigrationOutcome, error) {
	now := time.Now().UTC()

	done, err := store.IsMigratedToShared(ctx)
	if err != nil {
		return MigrationOutcome{RanAt: now}, fmt.Errorf("check migration sentinel: %w", err)
	}
	if done {
		return MigrationOutcome{RanAt: now, AlreadyDone: true}, nil
	}

	outcome := MigrationOutcome{RanAt: now}
	anyFailed := false
	for _, svc := range domain.AllMCPServices {
		result := migrateOneService(ctx, store, reg, svc)
		if result.Action == ActionFailed {
			anyFailed = true
		}
		outcome.ServiceResults = append(outcome.ServiceResults, result)
	}

	if anyFailed {
		// Skip sentinel write — next boot will retry. Successful services'
		// shared writes persist; the retry sees them as ActionKeptShared.
		return outcome, nil
	}
	if err := store.MarkMigratedToShared(ctx, now); err != nil {
		return outcome, fmt.Errorf("mark migration sentinel: %w", err)
	}
	return outcome, nil
}

// migrateOneService handles a single MCPService slot. Pure logic per service
// so failures on one service do not abort the rest (matches the existing
// DeleteAll non-atomic contract).
func migrateOneService(ctx context.Context, store port.MCPSecretStore, reg *domain.Registry, svc domain.MCPService) ServiceMigration {
	result := ServiceMigration{Service: svc, Action: ActionNoOp}

	candidates := candidateAccounts(reg, svc)
	result.CandidateCount = len(candidates)

	// Collect per-account payloads that actually have a secret.
	type liveCandidate struct {
		accountNum  int
		connectedAt time.Time
		payload     string
	}
	var live []liveCandidate
	for _, c := range candidates {
		payload, err := store.Read(ctx, c.accountNum, svc)
		if err != nil {
			result.Action = ActionFailed
			result.Error = fmt.Sprintf("read account %d: %v", c.accountNum, err)
			return result
		}
		if payload == "" {
			continue
		}
		live = append(live, liveCandidate{accountNum: c.accountNum, connectedAt: c.connectedAt, payload: payload})
	}
	if len(live) == 0 {
		return result
	}

	// Shared already populated → leave per-account entries alone, do nothing.
	sharedExisting, err := store.Read(ctx, 0, svc)
	if err != nil {
		result.Action = ActionFailed
		result.Error = fmt.Sprintf("read shared: %v", err)
		return result
	}
	if sharedExisting != "" {
		result.Action = ActionKeptShared
		return result
	}

	// Pick winner: most recently connected, tie-break by lowest account number.
	sort.SliceStable(live, func(i, j int) bool {
		if !live[i].connectedAt.Equal(live[j].connectedAt) {
			return live[i].connectedAt.After(live[j].connectedAt)
		}
		return live[i].accountNum < live[j].accountNum
	})
	winner := live[0]

	if err := store.Write(ctx, 0, svc, winner.payload); err != nil {
		result.Action = ActionFailed
		result.Error = fmt.Sprintf("write shared: %v", err)
		return result
	}
	result.Action = ActionCanonicalised
	result.WinningAccount = winner.accountNum
	return result
}

// candidateAccount is a (accountNumber, ConnectedAt) pair sourced from
// registry metadata. ConnectedAt may be zero when the account predates the
// connector metadata fields — handled by the sort tie-breaker.
type candidateAccount struct {
	accountNum  int
	connectedAt time.Time
}

func candidateAccounts(reg *domain.Registry, svc domain.MCPService) []candidateAccount {
	if reg == nil {
		return nil
	}
	out := make([]candidateAccount, 0, len(reg.Accounts))
	for num, acc := range reg.Accounts {
		if acc == nil || acc.MCPConnectors == nil {
			out = append(out, candidateAccount{accountNum: num})
			continue
		}
		c, ok := acc.MCPConnectors[svc]
		if !ok || c == nil {
			out = append(out, candidateAccount{accountNum: num})
			continue
		}
		out = append(out, candidateAccount{accountNum: num, connectedAt: c.ConnectedAt})
	}
	// Deterministic iteration order for tests.
	sort.Slice(out, func(i, j int) bool { return out[i].accountNum < out[j].accountNum })
	return out
}
