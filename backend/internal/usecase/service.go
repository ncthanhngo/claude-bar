// Package usecase composes ports into business operations the CLI exposes.
package usecase

import (
	"sync"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/cache"
	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// Service wires every port and exposes the operations.
type Service struct {
	Live       port.LiveCredentialStore
	Backup     port.BackupCredentialStore
	Config     port.ClaudeConfigStore
	Registry   port.RegistryStore
	Usage      port.UsageFetcher
	Refresh    port.TokenRefresher
	Sessions   port.SessionInspector
	Lock       port.FileLock
	MCPSecrets port.MCPSecretStore
	UsageLog   port.UsageLogScanner
	UsageCache *cache.UsageCache
	Backoff    *cache.Backoff

	// backupRefreshMu serialises per-account token refresh+write so concurrent
	// callers (list, verify, refresh-all, switch) cannot race on the same backup
	// when the OAuth provider rotates the refresh token on first use.
	backupRefreshMu sync.Map // value: *sync.Mutex

	// usageStats cache. The widget polls UsageStats every refreshIntervalSec
	// (default 30s); each scan walks ~/.claude/projects/**/*.jsonl which adds
	// up. Cache the report for usageStatsCacheTTL but always invalidate when
	// the current hour slot rolls over so the Hourly/Daily/Monthly series stay
	// in sync with the calendar boundary they advertise.
	usageStatsMu       sync.Mutex
	usageStatsCached   *domain.UsageStatsReport
	usageStatsCachedAt time.Time

	// mcpToolCostsOnce gates a one-shot computation of per-tool schema
	// token cost. The result feeds Settings → MCP's per-tool table so
	// users see "this tool costs X tokens per message". Computed lazily
	// the first time the widget asks for tool list — cheap (~tens of
	// ms) but no point paying it on every refresh.
	mcpToolCostsOnce  sync.Once
	mcpToolCostsCache map[string]int
}

// UsageStatsCacheTTL is the maximum age a cached report can serve before
// re-scanning the projects directory. Exposed for tests.
const UsageStatsCacheTTL = 5 * time.Minute

// lockBackupRefresh acquires the per-account mutex and returns an unlock func.
func (s *Service) lockBackupRefresh(accountNum int) func() {
	v, _ := s.backupRefreshMu.LoadOrStore(accountNum, new(sync.Mutex))
	mu := v.(*sync.Mutex)
	mu.Lock()
	return mu.Unlock
}
