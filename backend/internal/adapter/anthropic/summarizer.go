package anthropic

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// summarizeModel is a small, cheap Claude model — plenty for a short
// translate+condense task and far cheaper than the chat surface's default.
const summarizeModel = "claude-haiku-4-5-20251001"

// summarizeMaxTokens caps the response; a two-field JSON summary never
// needs the chat surface's 4096-token budget.
const summarizeMaxTokens = 500

// Summarizer wraps the existing OAuth-bound ChatClient to satisfy
// port.Summarizer — the Claude fallback used when Ollama is unavailable or
// disabled. News aggregation is a machine-wide (not per-account) operation,
// so it always runs on the currently ACTIVE account.
type Summarizer struct {
	chat     port.ChatClient
	tokens   port.OAuthTokenProvider
	registry port.RegistryStore
}

// NewSummarizer wires the three collaborators — same OAuth path the chat
// usecase uses (adapter/anthropic.ChatClient + oauth.TokenProvider).
func NewSummarizer(chat port.ChatClient, tokens port.OAuthTokenProvider, registry port.RegistryStore) *Summarizer {
	return &Summarizer{chat: chat, tokens: tokens, registry: registry}
}

// ModelName reports the fixed Claude model this summarizer pins internally
// — used only so callers (the news usecase) can report which model actually
// ran, e.g. for port.NewsFeed.Model. opts.Model is ignored by Summarize
// itself; this is the source of truth instead.
func (s *Summarizer) ModelName() string { return summarizeModel }

// Summarize implements port.Summarizer. opts.Model is ignored — the fallback
// pins its own small model rather than exposing Claude's full model catalog
// through the news config.
func (s *Summarizer) Summarize(ctx context.Context, item port.SummarizeInput, _ port.SummarizeOpts) (string, string, string, error) {
	reg, err := s.registry.Load(ctx)
	if err != nil {
		return "", "", "", fmt.Errorf("claude summarizer: load registry: %w", err)
	}
	if reg.ActiveAccountNumber == 0 {
		return "", "", "", errors.New("claude summarizer: no active account")
	}
	accessToken, _, err := s.tokens.GetFresh(ctx, reg.ActiveAccountNumber)
	if err != nil {
		return "", "", "", fmt.Errorf("claude summarizer: token: %w", err)
	}

	system, user := port.BuildSummarizePrompt(item)
	req := port.ChatRequest{
		Model:        summarizeModel,
		SystemPrompt: system,
		Messages: []domain.Message{{
			Role:    domain.RoleUser,
			Content: []domain.ContentBlock{{Kind: domain.BlockText, Text: user}},
		}},
		MaxTokens: summarizeMaxTokens,
		Stream:    true, // ChatClient only exposes a streaming surface
	}

	events, err := s.chat.Stream(ctx, accessToken, req)
	if err != nil {
		return "", "", "", fmt.Errorf("claude summarizer: stream: %w", err)
	}

	var text strings.Builder
	var streamErr error
	for ev := range events {
		switch ev.Kind {
		case domain.StreamTextDelta:
			text.WriteString(ev.Text)
		case domain.StreamError:
			streamErr = fmt.Errorf("claude summarizer: %s: %s", ev.ErrorCode, ev.ErrorMessage)
		}
	}
	if streamErr != nil {
		return "", "", "", streamErr
	}
	if text.Len() == 0 {
		return "", "", "", errors.New("claude summarizer: empty response")
	}

	titleVI, summaryVI, fullVI := port.ParseSummarizeJSON(text.String())
	return titleVI, summaryVI, fullVI, nil
}

// Compile-time guard.
var _ port.Summarizer = (*Summarizer)(nil)
