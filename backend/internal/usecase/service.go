// Package usecase composes ports into business operations the CLI exposes.
package usecase

import (
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
}
