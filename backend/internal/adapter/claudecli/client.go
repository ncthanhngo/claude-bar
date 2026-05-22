// Package claudecli implements port.ChatClient by shelling out to the
// locally-installed Claude Code CLI (`claude -p --output-format=stream-json
// --verbose --include-partial-messages`). This works around Anthropic's
// tight rate limit on OAuth Bearer hitting /v1/messages directly — the CLI
// uses an internal endpoint that gets the user's actual plan quota.
//
// The whole multi-turn history is flattened into a single prompt string
// sent on stdin (Claude doesn't expose multi-message-history via -p text
// mode without --resume). We forward the partial-message stream events
// back as ChatStreamEvent so the widget streaming UX stays unchanged.
package claudecli

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strings"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// ChatClient implements port.ChatClient on top of `claude -p`.
type ChatClient struct {
	BinaryPath string // resolved at construction; override via CLAUDE_BIN
}

// NewChatClient resolves the `claude` binary on PATH (or via CLAUDE_BIN
// env) and returns a ChatClient. Returns nil + error if the binary isn't
// available so the composition root can fall back to another adapter.
func NewChatClient() (*ChatClient, error) {
	bin := os.Getenv("CLAUDE_BIN")
	if bin == "" {
		p, err := exec.LookPath("claude")
		if err != nil {
			return nil, fmt.Errorf("claude binary not on PATH (install Claude Code or set CLAUDE_BIN)")
		}
		bin = p
	}
	return &ChatClient{BinaryPath: bin}, nil
}

// Stream spawns `claude -p` with the flattened history, parses the
// stream-json output line-by-line, and forwards translated events on the
// returned channel. The `accessToken` argument is ignored — the CLI reads
// OAuth from its own keychain entry (same one the user already manages
// through `csw switch`).
func (c *ChatClient) Stream(
	ctx context.Context,
	_ string,
	req port.ChatRequest,
) (<-chan domain.ChatStreamEvent, error) {
	prompt := flattenHistory(req)
	if prompt == "" {
		return nil, errors.New("claudecli: empty prompt")
	}
	model := req.Model
	if model == "" {
		model = "claude-sonnet-4-6"
	}

	args := []string{
		"-p",
		"--output-format=stream-json",
		"--verbose",
		"--include-partial-messages",
		"--model", model,
		"--allowedTools", "",
		"--disable-slash-commands",
	}
	if req.MaxTokens > 0 {
		// Claude CLI doesn't expose max_tokens directly; we soft-cap via
		// --max-budget-usd as a coarse safety. Skip for MVP.
		_ = req.MaxTokens
	}

	cmd := exec.CommandContext(ctx, c.BinaryPath, args...)
	cmd.Stdin = strings.NewReader(prompt)
	// Run from $HOME so the user's project CLAUDE.md / hooks / IDE
	// integrations don't bleed into the chat session.
	if home, err := os.UserHomeDir(); err == nil {
		cmd.Dir = home
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("claudecli: stdout pipe: %w", err)
	}
	stderrBuf := &strings.Builder{}
	cmd.Stderr = stderrLineWriter{w: stderrBuf}

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("claudecli: start: %w", err)
	}

	out := make(chan domain.ChatStreamEvent, 16)
	go func() {
		defer close(out)
		sc := bufio.NewScanner(stdout)
		sc.Buffer(make([]byte, 0, 64<<10), 4<<20)
		for sc.Scan() {
			line := sc.Text()
			if line == "" {
				continue
			}
			if ev, ok := decodeLine(line); ok {
				select {
				case out <- ev:
				case <-ctx.Done():
					_ = cmd.Process.Kill()
					return
				}
			}
		}
		if err := cmd.Wait(); err != nil {
			stderrTxt := strings.TrimSpace(stderrBuf.String())
			if stderrTxt == "" {
				stderrTxt = err.Error()
			}
			log.Printf("[claudecli] non-zero exit: %v; stderr: %s", err, stderrTxt)
			select {
			case out <- domain.ChatStreamEvent{
				Kind:         domain.StreamError,
				ErrorCode:    classifyExit(err, stderrTxt),
				ErrorMessage: stderrTxt,
			}:
			case <-ctx.Done():
			}
		}
	}()
	return out, nil
}

// stderrLineWriter mirrors stderr into our string builder so we can include
// useful diagnostics in the StreamError. Capped to avoid OOM on chatty
// hook output by trimming after ~16 KB.
type stderrLineWriter struct{ w *strings.Builder }

func (s stderrLineWriter) Write(p []byte) (int, error) {
	if s.w.Len() < 16*1024 {
		s.w.Write(p)
	}
	return len(p), nil
}

// classifyExit infers the error code from process exit + stderr content.
// CLI doesn't return structured errors; we pattern-match the most common
// failures. Anything we can't classify falls under "unknown".
func classifyExit(err error, stderr string) string {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return "cancelled"
	}
	lower := strings.ToLower(stderr)
	switch {
	case strings.Contains(lower, "rate limit"), strings.Contains(lower, "rate_limit"):
		return "rate_limited"
	case strings.Contains(lower, "overloaded"):
		return "overloaded"
	case strings.Contains(lower, "401"), strings.Contains(lower, "unauthorized"), strings.Contains(lower, "expired"):
		return "auth"
	case strings.Contains(lower, "model"), strings.Contains(lower, "404"):
		return "bad_request"
	}
	return "unknown"
}

// Compile-time guard: matches the port contract.
var _ port.ChatClient = (*ChatClient)(nil)
