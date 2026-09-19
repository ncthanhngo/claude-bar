package usecase

import (
	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/cache"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/claudeconfig"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/keychain"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/lock"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/oauth"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/registry"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/sessions"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/usagelog"
)

// NewMacOSService is the production composition root.
func NewMacOSService() *Service {
	live := keychain.NewLiveCredentialStore()
	refresh := oauth.NewTokenRefresher()
	config := claudeconfig.New()
	reg := registry.New()

	return &Service{
		Live:       live,
		Backup:     keychain.NewBackupCredentialStore(),
		Config:     config,
		Registry:   reg,
		Usage:      oauth.NewUsageFetcher(),
		Refresh:    refresh,
		Sessions:   sessions.New(),
		Lock:       lock.New(),
		MCPSecrets: keychain.NewMCPSecretStore(),
		UsageLog:   usagelog.NewScanner(adapter.ClaudeProjectsDir()),
		UsageCache: cache.New(),
		Backoff:    cache.NewBackoff(),
	}
}
