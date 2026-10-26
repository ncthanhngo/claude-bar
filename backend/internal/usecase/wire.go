package usecase

import (
	"fmt"
	"log"
	"os"
	"path/filepath"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/cache"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/claudeconfig"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/keychain"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/lock"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/oauth"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/registry"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/sessions"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/usagelog"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// NewMacOSService is the production composition root.
func NewMacOSService() *Service {
	live := keychain.NewLiveCredentialStore()
	refresh := oauth.NewTokenRefresher()
	config := claudeconfig.New()
	reg := registry.New()

	return &Service{
		Live:        live,
		Backup:      keychain.NewBackupCredentialStore(),
		Config:      config,
		Registry:    reg,
		Usage:       oauth.NewUsageFetcher(),
		Refresh:     refresh,
		Sessions:    sessions.New(),
		Lock:        lock.New(),
		MCPSecrets:  keychain.NewMCPSecretStore(),
		RefreshLock: lock.NewClaudeRefreshLockWait(),
		BackupRefreshLock: func() port.FileLock {
			return lock.NewAt(adapter.BackupRefreshLockFile())
		},
		Log: openCswLog(),
		UsageLog: usagelog.NewScanner(adapter.ClaudeProjectsDir()).
			WithCacheFile(filepath.Join(adapter.WidgetDataDir(), "usage", "scan-cache.json")),
		UsageCache: cache.New(),
		Backoff:    cache.NewBackoff(),
	}
}

// cswLogMaxBytes caps csw.log; past it the file restarts empty.
const cswLogMaxBytes = 2 << 20

// openCswLog appends to csw.log, or returns nil (discard) when it can't.
func openCswLog() *log.Logger {
	path := adapter.CswLogFile()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil
	}
	if info, err := os.Stat(path); err == nil && info.Size() > cswLogMaxBytes {
		_ = os.Remove(path)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil
	}
	return log.New(f, fmt.Sprintf("[%d] ", os.Getpid()), log.LstdFlags|log.Lmsgprefix)
}
