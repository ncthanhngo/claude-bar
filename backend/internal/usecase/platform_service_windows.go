//go:build windows

package usecase

import (
	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/cache"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/claudeconfig"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/lock"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/oauth"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/registry"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/sessions"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/wincreds"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// NewPlatformService is the composition root for this OS.
func NewPlatformService() *Service { return NewWindowsService() }

// NewWindowsService wires the account-swap subset: live login where Claude
// Code keeps it, DPAPI backups, and the same locks and logs as macOS.
func NewWindowsService() *Service {
	return &Service{
		Live:        wincreds.NewLiveStore(),
		Backup:      wincreds.NewBackupStore(),
		Config:      claudeconfig.New(),
		Registry:    registry.New(),
		Usage:       oauth.NewUsageFetcher(),
		Profile:     oauth.NewProfileFetcher(),
		Refresh:     oauth.NewTokenRefresher(),
		Sessions:    sessions.New(),
		Lock:        lock.New(),
		RefreshLock: lock.NewClaudeRefreshLockWait(),
		BackupRefreshLock: func() port.FileLock {
			return lock.NewAt(adapter.BackupRefreshLockFile())
		},
		Log:        openCswLog(),
		UsageCache: cache.New(),
		Backoff:    cache.NewBackoff(),
	}
}
