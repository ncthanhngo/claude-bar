// Package usecase composes ports into business operations the CLI exposes.
package usecase

import (
	"sync"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/cache"
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
	UsageCache *cache.UsageCache
	Backoff    *cache.Backoff

	// backupRefreshMu serialises per-account token refresh+write so concurrent
	// callers (list, verify, refresh-all, switch) cannot race on the same backup
	// when the OAuth provider rotates the refresh token on first use.
	backupRefreshMu sync.Map // value: *sync.Mutex
}

// lockBackupRefresh acquires the per-account mutex and returns an unlock func.
func (s *Service) lockBackupRefresh(accountNum int) func() {
	v, _ := s.backupRefreshMu.LoadOrStore(accountNum, new(sync.Mutex))
	mu := v.(*sync.Mutex)
	mu.Lock()
	return mu.Unlock
}
