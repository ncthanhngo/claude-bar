package news

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// fakeSummarizer is a minimal port.Summarizer test double that records how
// many times it was called and returns a canned result/error. calls is
// accessed with atomic ops since Aggregator.Fetch now runs Summarize calls
// concurrently (bounded worker pool) — a plain int++ here would race under
// `go test -race`.
type fakeSummarizer struct {
	titleVI, summaryVI, fullVI string
	err                        error
	calls                      int32
}

func (f *fakeSummarizer) Summarize(_ context.Context, _ port.SummarizeInput, _ port.SummarizeOpts) (string, string, string, error) {
	atomic.AddInt32(&f.calls, 1)
	return f.titleVI, f.summaryVI, f.fullVI, f.err
}

func TestProviderRouter_FallsBackToClaudeWhenOllamaFails(t *testing.T) {
	ollama := &fakeSummarizer{err: errors.New("connection refused")}
	claude := &fakeSummarizer{summaryVI: "tóm tắt", fullVI: "bản dịch đầy đủ"}
	router := NewProviderRouter(ollama, claude)

	cfg := port.NewsConfig{Provider: "ollama", ClaudeFallbackEnabled: true}
	result, err := router.Summarize(context.Background(), port.SummarizeInput{Title: "x"}, cfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Provider != "claude" {
		t.Errorf("provider = %q, want claude", result.Provider)
	}
	if result.SummaryVI != "tóm tắt" || result.FullVI != "bản dịch đầy đủ" {
		t.Errorf("unexpected result: %+v", result)
	}
	if ollama.calls != 1 {
		t.Errorf("ollama.calls = %d, want 1", ollama.calls)
	}
	if claude.calls != 1 {
		t.Errorf("claude.calls = %d, want 1", claude.calls)
	}
}

func TestProviderRouter_NoFallbackWhenDisabled(t *testing.T) {
	ollama := &fakeSummarizer{err: errors.New("down")}
	claude := &fakeSummarizer{summaryVI: "x", fullVI: "y"}
	router := NewProviderRouter(ollama, claude)

	cfg := port.NewsConfig{Provider: "ollama", ClaudeFallbackEnabled: false}
	_, err := router.Summarize(context.Background(), port.SummarizeInput{Title: "x"}, cfg)
	if err == nil {
		t.Fatal("expected error when fallback disabled and ollama fails")
	}
	if claude.calls != 0 {
		t.Errorf("claude should not be called, calls=%d", claude.calls)
	}
}

func TestProviderRouter_OllamaSuccessSkipsFallback(t *testing.T) {
	ollama := &fakeSummarizer{titleVI: "tiêu đề", summaryVI: "tóm tắt", fullVI: "đầy đủ"}
	claude := &fakeSummarizer{}
	router := NewProviderRouter(ollama, claude)

	cfg := port.NewsConfig{Provider: "ollama", ClaudeFallbackEnabled: true}
	result, err := router.Summarize(context.Background(), port.SummarizeInput{Title: "x"}, cfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Provider != "ollama" {
		t.Errorf("provider = %q, want ollama", result.Provider)
	}
	if result.TitleVI != "tiêu đề" {
		t.Errorf("TitleVI = %q, want propagated from the summarizer", result.TitleVI)
	}
	if claude.calls != 0 {
		t.Errorf("claude should not be called, calls=%d", claude.calls)
	}
}

func TestProviderRouter_NilOllamaFallsBackWhenEnabled(t *testing.T) {
	claude := &fakeSummarizer{summaryVI: "a", fullVI: "b"}
	router := NewProviderRouter(nil, claude)

	cfg := port.NewsConfig{Provider: "ollama", ClaudeFallbackEnabled: true}
	result, err := router.Summarize(context.Background(), port.SummarizeInput{Title: "x"}, cfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Provider != "claude" {
		t.Errorf("provider = %q, want claude", result.Provider)
	}
}

func TestProviderRouter_NilOllamaNoFallbackErrors(t *testing.T) {
	router := NewProviderRouter(nil, &fakeSummarizer{})
	cfg := port.NewsConfig{Provider: "ollama", ClaudeFallbackEnabled: false}
	_, err := router.Summarize(context.Background(), port.SummarizeInput{Title: "x"}, cfg)
	if err == nil {
		t.Fatal("expected error: ollama unavailable and fallback disabled")
	}
}

// fakeResolvingSummarizer additionally implements modelResolver, mimicking
// adapter/ollama.Client's "pick installed model at runtime" behaviour.
type fakeResolvingSummarizer struct {
	fakeSummarizer
	resolved string
	resolErr error
}

func (f *fakeResolvingSummarizer) ResolveModel(_ context.Context, configured string) (string, error) {
	if configured != "" {
		return configured, nil
	}
	return f.resolved, f.resolErr
}

// fakeNamedSummarizer additionally implements namedModel, mimicking
// adapter/anthropic.Summarizer's fixed-model behaviour.
type fakeNamedSummarizer struct {
	fakeSummarizer
	name string
}

func (f *fakeNamedSummarizer) ModelName() string { return f.name }

func TestProviderRouter_ResolveModel(t *testing.T) {
	ollama := &fakeResolvingSummarizer{resolved: "qwen2.5:14b"}
	claude := &fakeNamedSummarizer{name: "claude-haiku-4-5-20251001"}
	router := NewProviderRouter(ollama, claude)

	if got := router.ResolveModel(context.Background(), "ollama", port.NewsConfig{}); got != "qwen2.5:14b" {
		t.Errorf("ResolveModel(ollama, no configured model) = %q, want the auto-picked model", got)
	}
	if got := router.ResolveModel(context.Background(), "ollama", port.NewsConfig{OllamaModel: "llama3.1"}); got != "llama3.1" {
		t.Errorf("ResolveModel(ollama, configured) = %q, want the configured model", got)
	}
	if got := router.ResolveModel(context.Background(), "claude", port.NewsConfig{}); got != "claude-haiku-4-5-20251001" {
		t.Errorf("ResolveModel(claude) = %q, want the pinned Claude model", got)
	}
}

func TestProviderRouter_ResolveModelFallsBackWhenUnsupported(t *testing.T) {
	router := NewProviderRouter(&fakeSummarizer{}, &fakeSummarizer{})
	if got := router.ResolveModel(context.Background(), "ollama", port.NewsConfig{OllamaModel: "configured"}); got != "configured" {
		t.Errorf("ResolveModel = %q, want the configured value when the summarizer exposes no resolver", got)
	}
	if got := router.ResolveModel(context.Background(), "claude", port.NewsConfig{}); got != "" {
		t.Errorf("ResolveModel = %q, want empty when the summarizer exposes no ModelName()", got)
	}
}

// fakeTranslatingSummarizer additionally implements port.ArticleTranslator,
// mimicking ollama.Client/anthropic.Summarizer's full-article translation
// capability.
type fakeTranslatingSummarizer struct {
	fakeSummarizer
	titleVI, contentVI string
	translateErr       error
	translateCalls     int32
}

func (f *fakeTranslatingSummarizer) TranslateArticle(_ context.Context, _ port.ArticleTranslateInput, _ port.SummarizeOpts) (string, string, error) {
	atomic.AddInt32(&f.translateCalls, 1)
	return f.titleVI, f.contentVI, f.translateErr
}

func TestProviderRouter_Translate_OllamaSuccess(t *testing.T) {
	ollama := &fakeTranslatingSummarizer{titleVI: "Tiêu đề", contentVI: "Nội dung đầy đủ"}
	claude := &fakeTranslatingSummarizer{}
	router := NewProviderRouter(ollama, claude)

	cfg := port.NewsConfig{Provider: "ollama"}
	result, err := router.Translate(context.Background(), port.ArticleTranslateInput{Title: "x"}, cfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Provider != "ollama" || result.ContentVI != "Nội dung đầy đủ" {
		t.Errorf("result = %+v", result)
	}
	if claude.translateCalls != 0 {
		t.Errorf("claude should not be called, calls=%d", claude.translateCalls)
	}
}

func TestProviderRouter_Translate_FallsBackToClaudeWhenOllamaFails(t *testing.T) {
	ollama := &fakeTranslatingSummarizer{translateErr: errors.New("timeout")}
	claude := &fakeTranslatingSummarizer{titleVI: "T", contentVI: "C"}
	router := NewProviderRouter(ollama, claude)

	cfg := port.NewsConfig{Provider: "ollama", ClaudeFallbackEnabled: true}
	result, err := router.Translate(context.Background(), port.ArticleTranslateInput{Title: "x"}, cfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Provider != "claude" || result.ContentVI != "C" {
		t.Errorf("result = %+v", result)
	}
}

func TestProviderRouter_Translate_NoFallbackWhenDisabled(t *testing.T) {
	ollama := &fakeTranslatingSummarizer{translateErr: errors.New("down")}
	claude := &fakeTranslatingSummarizer{titleVI: "T", contentVI: "C"}
	router := NewProviderRouter(ollama, claude)

	cfg := port.NewsConfig{Provider: "ollama", ClaudeFallbackEnabled: false}
	_, err := router.Translate(context.Background(), port.ArticleTranslateInput{Title: "x"}, cfg)
	if err == nil {
		t.Fatal("expected error when fallback disabled and ollama translate fails")
	}
	if claude.translateCalls != 0 {
		t.Errorf("claude should not be called, calls=%d", claude.translateCalls)
	}
}

func TestProviderRouter_Translate_ErrorsWhenProviderLacksCapability(t *testing.T) {
	// A plain fakeSummarizer implements port.Summarizer but not
	// port.ArticleTranslator — Translate must fail cleanly, not panic.
	router := NewProviderRouter(&fakeSummarizer{}, nil)
	cfg := port.NewsConfig{Provider: "ollama"}
	if _, err := router.Translate(context.Background(), port.ArticleTranslateInput{Title: "x"}, cfg); err == nil {
		t.Fatal("expected error when the provider doesn't implement ArticleTranslator")
	}
}

func TestProviderRouter_ClaudePrimaryHasNoFurtherFallback(t *testing.T) {
	ollama := &fakeSummarizer{summaryVI: "should not be used"}
	claude := &fakeSummarizer{err: errors.New("claude down")}
	router := NewProviderRouter(ollama, claude)

	cfg := port.NewsConfig{Provider: "claude", ClaudeFallbackEnabled: true}
	_, err := router.Summarize(context.Background(), port.SummarizeInput{Title: "x"}, cfg)
	if err == nil {
		t.Fatal("expected error: claude primary failed, no fallback beyond it")
	}
	if ollama.calls != 0 {
		t.Errorf("ollama should never be called when provider=claude, calls=%d", ollama.calls)
	}
}
