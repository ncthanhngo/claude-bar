package briefing

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/mcp"
)

// ClaudeRunner shells out to the locally-installed `claude` CLI to summarize
// the briefing. Uses the active Claude Bar account's credentials (already
// wired via the menu bar app), so no API key is needed.
type ClaudeRunner struct {
	BinaryPath string        // resolved at construction, override via CLAUDE_BIN env
	Model      string        // e.g. "claude-sonnet-4-6"
	Timeout    time.Duration // total wall clock per attempt
}

// DefaultClaudeRunner returns a runner with Sonnet 4.6 + 60s timeout.
func DefaultClaudeRunner() (*ClaudeRunner, error) {
	bin := os.Getenv("CLAUDE_BIN")
	if bin == "" {
		p, err := exec.LookPath("claude")
		if err != nil {
			return nil, fmt.Errorf("claude binary not on PATH (install Claude Code or set CLAUDE_BIN)")
		}
		bin = p
	}
	return &ClaudeRunner{
		BinaryPath: bin,
		Model:      "claude-sonnet-4-6",
		Timeout:    60 * time.Second,
	}, nil
}

// Summarize runs the prompt through Claude once, retries once with a stricter
// suffix if JSON parse fails, and returns the parsed payload. Caller falls
// back to rule-based ranker on returned error.
func (r *ClaudeRunner) Summarize(ctx context.Context, prompt string) (*BriefingPayload, error) {
	payload, err := r.runOnce(ctx, prompt)
	if err == nil {
		return payload, nil
	}
	retry := prompt + "\n\nLỗi parse JSON ở lượt trước. Output lại CHỈ một JSON object hợp lệ, không markdown, không bình luận."
	return r.runOnce(ctx, retry)
}

// claudeEnvelope mirrors `claude -p --output-format=json` shape.
type claudeEnvelope struct {
	Type     string `json:"type"`
	Subtype  string `json:"subtype"`
	IsError  bool   `json:"is_error"`
	Result   string `json:"result"`
	Duration int    `json:"duration_ms"`
}

func (r *ClaudeRunner) runOnce(ctx context.Context, prompt string) (*BriefingPayload, error) {
	result, err := r.RunText(ctx, prompt)
	if err != nil {
		return nil, err
	}

	var payload BriefingPayload
	if err := json.Unmarshal([]byte(extractJSONObject(result)), &payload); err != nil {
		return nil, fmt.Errorf("payload decode: %w", err)
	}
	return &payload, nil
}

// RunText runs one prompt through the `claude` CLI and returns the raw result
// string (the envelope's `result` field, trimmed). Shared by the briefing
// summarizer and the Workspace action drafter.
func (r *ClaudeRunner) RunText(ctx context.Context, prompt string) (string, error) {
	cctx, cancel := context.WithTimeout(ctx, r.Timeout)
	defer cancel()

	// Pass prompt via stdin to avoid argv leakage (visible via `ps`).
	cmd := exec.CommandContext(cctx, r.BinaryPath,
		"-p", "--output-format=json",
		"--model", r.Model,
		"--allowedTools", "",
	)
	cmd.Stdin = strings.NewReader(prompt)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		stderrStr := mcp.Redact(strings.TrimSpace(stderr.String()))
		if errors.Is(cctx.Err(), context.DeadlineExceeded) {
			return "", fmt.Errorf("claude timeout after %s: %s", r.Timeout, stderrStr)
		}
		return "", fmt.Errorf("claude exit: %w: %s", err, stderrStr)
	}

	var env claudeEnvelope
	if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
		return "", fmt.Errorf("claude envelope decode: %w", err)
	}
	if env.IsError || env.Result == "" {
		return "", fmt.Errorf("claude returned error envelope")
	}
	return strings.TrimSpace(env.Result), nil
}

// extractJSONObject trims any prose around a JSON object some models emit,
// returning the substring from the first `{` to the last `}`.
func extractJSONObject(s string) string {
	if i := strings.Index(s, "{"); i >= 0 {
		if j := strings.LastIndex(s, "}"); j > i {
			return s[i : j+1]
		}
	}
	return s
}
