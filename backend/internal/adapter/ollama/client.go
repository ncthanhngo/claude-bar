// Package ollama implements port.Summarizer against a local Ollama server
// (http://localhost:11434) — the default news-dashboard AI provider. No
// auth, no secrets: it's a plain loopback HTTP call.
package ollama

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

const (
	defaultBaseURL = "http://localhost:11434"
	// probeTimeout bounds GET /api/tags — used both to discover a default
	// model and to answer `csw news providers` quickly even when Ollama
	// isn't running at all.
	probeTimeout = 3 * time.Second
	// chatTimeout bounds one summarise+translate call. Local models can be
	// slow on modest hardware, so this is generous relative to the network
	// calls elsewhere in the CLI.
	chatTimeout = 60 * time.Second
	// articleChatTimeout bounds one full-article translation call — the
	// input can be ~8000 chars and the output a similarly long Vietnamese
	// translation, which takes local CPU-bound models minutes rather than
	// seconds; far longer than the short RSS-summary path above.
	articleChatTimeout = 5 * time.Minute
)

// Client talks to the Ollama HTTP API. Stateless beyond baseURL — safe for
// concurrent use.
type Client struct {
	baseURL string
	hc      *http.Client
}

// NewClient returns a Client pointed at the local Ollama server.
func NewClient() *Client {
	return &Client{baseURL: defaultBaseURL, hc: &http.Client{}}
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type chatRequest struct {
	Model    string        `json:"model"`
	Messages []chatMessage `json:"messages"`
	Stream   bool          `json:"stream"`
	// Format "json" asks Ollama to constrain output to valid JSON on models
	// that support structured output — a best-effort nudge; ParseSummarizeJSON
	// still tolerates a model that ignores it.
	Format string `json:"format,omitempty"`
}

type chatResponse struct {
	Message chatMessage `json:"message"`
	Done    bool        `json:"done"`
}

// Summarize implements port.Summarizer via POST /api/chat (non-streaming).
// When opts.Model is empty it picks the first installed model — the
// "pick installed model at runtime" default from the plan's open question.
func (c *Client) Summarize(ctx context.Context, item port.SummarizeInput, opts port.SummarizeOpts) (string, string, string, error) {
	model, err := c.ResolveModel(ctx, opts.Model)
	if err != nil {
		return "", "", "", err
	}

	system, user := port.BuildSummarizePrompt(item)
	body, err := json.Marshal(chatRequest{
		Model: model,
		Messages: []chatMessage{
			{Role: "system", Content: system},
			{Role: "user", Content: user},
		},
		Stream: false,
		Format: "json",
	})
	if err != nil {
		return "", "", "", fmt.Errorf("ollama: encode request: %w", err)
	}

	callCtx, cancel := context.WithTimeout(ctx, chatTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(callCtx, http.MethodPost, c.baseURL+"/api/chat", bytes.NewReader(body))
	if err != nil {
		return "", "", "", fmt.Errorf("ollama: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.hc.Do(req)
	if err != nil {
		return "", "", "", fmt.Errorf("ollama: chat request failed (is Ollama running on %s?): %w", c.baseURL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return "", "", "", fmt.Errorf("ollama: chat status %d", resp.StatusCode)
	}

	var out chatResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", "", "", fmt.Errorf("ollama: decode response: %w", err)
	}

	titleVI, summaryVI, fullVI := port.ParseSummarizeJSON(out.Message.Content)
	if summaryVI == "" && fullVI == "" {
		return "", "", "", errors.New("ollama: empty summary response")
	}
	return titleVI, summaryVI, fullVI, nil
}

// ResolveModel returns configured if non-empty, otherwise the first
// installed Ollama model — the same "pick installed model at runtime"
// policy Summarize applies internally. Exposed separately so callers (the
// news usecase) can report which model actually ran, e.g. for
// port.NewsFeed.Model, without re-deriving the selection logic or forcing
// every Summarize call to thread a model name back out.
func (c *Client) ResolveModel(ctx context.Context, configured string) (string, error) {
	if configured != "" {
		return configured, nil
	}
	models, err := c.ListModels(ctx)
	if err != nil {
		return "", fmt.Errorf("ollama: no model configured and listing models failed: %w", err)
	}
	if len(models) == 0 {
		return "", errors.New("ollama: no models installed")
	}
	return models[0], nil
}

// TranslateArticle implements port.ArticleTranslator via POST /api/chat —
// same transport as Summarize, but with articleTranslatePrompt (full
// paragraph-preserving translation, no condensing) and a much longer
// timeout since the input/output are a whole article body rather than a
// short RSS snippet.
func (c *Client) TranslateArticle(ctx context.Context, item port.ArticleTranslateInput, opts port.SummarizeOpts) (string, string, error) {
	model, err := c.ResolveModel(ctx, opts.Model)
	if err != nil {
		return "", "", err
	}

	system, user := port.BuildTranslatePrompt(item)
	body, err := json.Marshal(chatRequest{
		Model: model,
		Messages: []chatMessage{
			{Role: "system", Content: system},
			{Role: "user", Content: user},
		},
		Stream: false,
		Format: "json",
	})
	if err != nil {
		return "", "", fmt.Errorf("ollama: encode request: %w", err)
	}

	callCtx, cancel := context.WithTimeout(ctx, articleChatTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(callCtx, http.MethodPost, c.baseURL+"/api/chat", bytes.NewReader(body))
	if err != nil {
		return "", "", fmt.Errorf("ollama: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.hc.Do(req)
	if err != nil {
		return "", "", fmt.Errorf("ollama: chat request failed (is Ollama running on %s?): %w", c.baseURL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return "", "", fmt.Errorf("ollama: chat status %d", resp.StatusCode)
	}

	var out chatResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", "", fmt.Errorf("ollama: decode response: %w", err)
	}

	titleVI, contentVI := port.ParseTranslateJSON(out.Message.Content)
	if contentVI == "" {
		return "", "", errors.New("ollama: empty translation response")
	}
	return titleVI, contentVI, nil
}

// Compile-time guard: Client implements the optional article-translate
// capability too.
var _ port.ArticleTranslator = (*Client)(nil)

type tagsResponse struct {
	Models []struct {
		Name string `json:"name"`
	} `json:"models"`
}

// ListModels returns installed model names via GET /api/tags. Used both to
// pick a default model in Summarize and to populate `csw news providers`.
func (c *Client) ListModels(ctx context.Context) ([]string, error) {
	probeCtx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(probeCtx, http.MethodGet, c.baseURL+"/api/tags", nil)
	if err != nil {
		return nil, fmt.Errorf("ollama: build tags request: %w", err)
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("ollama: tags request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("ollama: tags status %d", resp.StatusCode)
	}
	var out tagsResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("ollama: decode tags: %w", err)
	}
	names := make([]string, 0, len(out.Models))
	for _, m := range out.Models {
		names = append(names, m.Name)
	}
	return names, nil
}

// Available reports whether the local Ollama server answers at all — used
// by `csw news providers` to set ollamaAvailable even with zero models
// installed (distinguishes "not running" from "running, nothing pulled").
func (c *Client) Available(ctx context.Context) bool {
	_, err := c.ListModels(ctx)
	return err == nil
}

// Compile-time guard: Client implements the port.
var _ port.Summarizer = (*Client)(nil)
