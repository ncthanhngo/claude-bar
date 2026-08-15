// Package news implements the news-dashboard aggregation usecase: fetch
// feeds + GitHub repos, pick an AI provider (with fallback), translate/
// summarise each item to Vietnamese, and assemble one NewsFeed snapshot.
package news

import (
	"context"
	"errors"
	"fmt"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// ProviderResult is one successful Summarize call: the Vietnamese text plus
// which provider actually produced it (differs from cfg.Provider when an
// Ollama failure triggered the Claude fallback).
type ProviderResult struct {
	TitleVI   string
	SummaryVI string
	FullVI    string
	Provider  string
}

// ProviderRouter selects between the configured primary provider and an
// optional Claude fallback. Either summarizer may be nil (Ollama not
// installed / no active Claude account) — Summarize surfaces a clear error
// in that case instead of a nil-pointer panic.
type ProviderRouter struct {
	Ollama port.Summarizer
	Claude port.Summarizer
}

// NewProviderRouter wires the two candidate summarizers.
func NewProviderRouter(ollama, claude port.Summarizer) *ProviderRouter {
	return &ProviderRouter{Ollama: ollama, Claude: claude}
}

// Summarize tries cfg.Provider first. When that's "ollama" and it fails, it
// retries with Claude iff cfg.ClaudeFallbackEnabled — the one fallback path
// the plan calls for. A "claude"-primary config has no further fallback
// (there's nothing more local to fall back to).
func (r *ProviderRouter) Summarize(ctx context.Context, item port.SummarizeInput, cfg port.NewsConfig) (ProviderResult, error) {
	primary := cfg.Provider
	if primary == "" {
		primary = "ollama"
	}

	if primary == "claude" {
		return r.tryClaude(ctx, item)
	}

	if r.Ollama != nil {
		titleVI, summaryVI, fullVI, err := r.Ollama.Summarize(ctx, item, port.SummarizeOpts{
			Provider: "ollama", Model: cfg.OllamaModel, TargetLang: "vi",
		})
		if err == nil {
			return ProviderResult{TitleVI: titleVI, SummaryVI: summaryVI, FullVI: fullVI, Provider: "ollama"}, nil
		}
		if !cfg.ClaudeFallbackEnabled {
			return ProviderResult{}, fmt.Errorf("ollama: %w", err)
		}
	} else if !cfg.ClaudeFallbackEnabled {
		return ProviderResult{}, errors.New("ollama summarizer unavailable and claude fallback disabled")
	}

	return r.tryClaude(ctx, item)
}

func (r *ProviderRouter) tryClaude(ctx context.Context, item port.SummarizeInput) (ProviderResult, error) {
	if r.Claude == nil {
		return ProviderResult{}, errors.New("claude summarizer unavailable")
	}
	titleVI, summaryVI, fullVI, err := r.Claude.Summarize(ctx, item, port.SummarizeOpts{Provider: "claude", TargetLang: "vi"})
	if err != nil {
		return ProviderResult{}, fmt.Errorf("claude: %w", err)
	}
	return ProviderResult{TitleVI: titleVI, SummaryVI: summaryVI, FullVI: fullVI, Provider: "claude"}, nil
}

// modelResolver is the optional capability a port.Summarizer implementation
// may expose so ResolveModel can report the actual model that ran (e.g. the
// auto-picked Ollama model from /api/tags) without widening the core
// Summarizer interface with an output-only field every implementation would
// have to thread through. adapter/ollama.Client implements it.
type modelResolver interface {
	ResolveModel(ctx context.Context, configured string) (string, error)
}

// namedModel is the equivalent optional capability for a summarizer that
// pins one fixed model rather than resolving one at runtime.
// adapter/anthropic.Summarizer implements it.
type namedModel interface {
	ModelName() string
}

// ResolveModel reports the actual model name behind providerUsed (the
// Provider field a prior Summarize call returned), for NewsFeed.Model.
// Best-effort: returns "" if the underlying summarizer exposes neither
// optional capability, or model resolution fails.
func (r *ProviderRouter) ResolveModel(ctx context.Context, providerUsed string, cfg port.NewsConfig) string {
	switch providerUsed {
	case "claude":
		if named, ok := r.Claude.(namedModel); ok {
			return named.ModelName()
		}
		return ""
	default: // "ollama"
		if resolver, ok := r.Ollama.(modelResolver); ok {
			if model, err := resolver.ResolveModel(ctx, cfg.OllamaModel); err == nil {
				return model
			}
		}
		return cfg.OllamaModel
	}
}
