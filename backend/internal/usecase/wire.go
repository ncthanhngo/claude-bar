package usecase

import (
	"path/filepath"

	"github.com/soi/claude-swap-widget/backend/internal/adapter"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/anthropic"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/cache"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/claudeconfig"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/keychain"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/lock"
	newsstore "github.com/soi/claude-swap-widget/backend/internal/adapter/news_store"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/newsfetch"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/oauth"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/ollama"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/registry"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/sessions"
	sshadp "github.com/soi/claude-swap-widget/backend/internal/adapter/ssh"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/usagelog"
	"github.com/soi/claude-swap-widget/backend/internal/usecase/news"
)

// NewMacOSService is the production composition root.
func NewMacOSService() *Service {
	live := keychain.NewLiveCredentialStore()
	refresh := oauth.NewTokenRefresher()
	config := claudeconfig.New()
	reg := registry.New()

	// News AI providers: Ollama (local, default) + Claude (fallback, reuses
	// the same OAuth-bound chat path as the chat surface — always runs on
	// the currently active account since aggregation is machine-wide).
	tokenProvider := oauth.NewTokenProvider(live, refresh, config, reg)
	claudeSummarizer := anthropic.NewSummarizer(anthropic.NewChatClient(), tokenProvider, reg)
	ollamaClient := ollama.NewClient()
	router := news.NewProviderRouter(ollamaClient, claudeSummarizer)
	aggregator := news.NewAggregator(newsfetch.NewRSS(), newsfetch.NewGitHub(), newsfetch.NewImage(), router)
	newsStore := newsstore.NewStore()

	// Master/Client SSH relay sync (P4) shares the same tracked-host
	// registry the SSH/backup/server-assistant surfaces already use.
	sshHosts := sshadp.NewHostStore(filepath.Join(adapter.WidgetDataDir(), "ssh", "hosts.json"))

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

		NewsAggregator: aggregator,
		NewsStore:      newsStore,
		NewsPublisher:  news.NewPublisher(sshHosts),
		NewsPuller:     news.NewPuller(sshHosts, newsStore),
		NewsArticles:   news.NewArticleService(newsfetch.NewArticle(), router, newsStore),
	}
}
