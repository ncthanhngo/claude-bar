package usecase

import (
	"github.com/soi/claude-swap-widget/backend/internal/adapter/cache"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/claudeconfig"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/keychain"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/lock"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/oauth"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/registry"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/sessions"
)

// NewMacOSService is the production composition root.
func NewMacOSService() *Service {
	return &Service{
		Live:       keychain.NewLiveCredentialStore(),
		Backup:     keychain.NewBackupCredentialStore(),
		Config:     claudeconfig.New(),
		Registry:   registry.New(),
		Usage:      oauth.NewUsageFetcher(),
		Refresh:    oauth.NewTokenRefresher(),
		Sessions:   sessions.New(),
		Lock:       lock.New(),
		MCPSecrets: keychain.NewMCPSecretStore(),
		UsageCache: cache.New(),
		Backoff:    cache.NewBackoff(),
	}
}
