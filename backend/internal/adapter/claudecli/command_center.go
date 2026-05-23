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
	"sync"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// CommandCenterOptions controls Phase 4 spawn behaviour. Values left at the
// zero value preserve the existing chat-tab Stream behaviour (no permission
// mode flag, inherited env, no context injection).
type CommandCenterOptions struct {
	// PermissionMode → `--permission-mode plan|acceptEdits|bypassPermissions`.
	// Validated by Preflight(); spawn errors clean if the flag is missing on
	// the user's `claude` CLI.
	PermissionMode string

	// SystemPromptAppend → `--append-system-prompt <text>`. Used for the
	// once-per-session context injection (active repo, ssh host, briefing
	// focus). Empty means no append flag.
	SystemPromptAppend string

	// AccountConfigDir → `CLAUDE_CONFIG_DIR` env override pinning the spawn
	// to one Claude account. Empty inherits the parent process's value.
	AccountConfigDir string

	// Cwd overrides the spawn working directory. Empty means $HOME (current
	// chat-tab default).
	Cwd string
}

// StreamCommandCenter is the Phase-4 entrypoint: same stream-json output
// shape as Stream, but with sanitised env, optional permission-mode flag,
// optional append-system-prompt, optional CLAUDE_CONFIG_DIR override, and a
// single-slot mutex so two Command-Center sessions never spawn concurrently
// (separate from chat tab's lockless path).
func (c *ChatClient) StreamCommandCenter(
	ctx context.Context,
	req port.ChatRequest,
	opts CommandCenterOptions,
) (<-chan domain.ChatStreamEvent, error) {
	if !commandCenterSlot.tryAcquire() {
		return nil, ErrCommandCenterBusy
	}

	prompt := flattenHistory(req)
	if prompt == "" {
		commandCenterSlot.release()
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
	}
	args = append(args, toolModeArgs(os.Getenv("CB_CHAT_TOOL_MODE"))...)
	if opts.PermissionMode != "" {
		args = append(args, "--permission-mode", opts.PermissionMode)
	}
	if opts.SystemPromptAppend != "" {
		args = append(args, "--append-system-prompt", opts.SystemPromptAppend)
	}

	cmd := exec.CommandContext(ctx, c.BinaryPath, args...)
	cmd.Stdin = strings.NewReader(prompt)
	cmd.Env = sanitisedEnv(opts.AccountConfigDir)
	if opts.Cwd != "" {
		cmd.Dir = opts.Cwd
	} else if home, err := os.UserHomeDir(); err == nil {
		cmd.Dir = home
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		commandCenterSlot.release()
		return nil, fmt.Errorf("claudecli: stdout pipe: %w", err)
	}
	stderrBuf := &strings.Builder{}
	cmd.Stderr = stderrLineWriter{w: stderrBuf}

	if err := cmd.Start(); err != nil {
		commandCenterSlot.release()
		return nil, fmt.Errorf("claudecli: start: %w", err)
	}

	out := make(chan domain.ChatStreamEvent, 16)
	go func() {
		defer close(out)
		defer commandCenterSlot.release()
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
			log.Printf("[claudecli/cmdctr] non-zero exit: %v; stderr: %s", err, stderrTxt)
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

// ErrCommandCenterBusy is returned when a second StreamCommandCenter call
// fires while one is in flight. Callers (the queue layer in usecase/chat)
// should park the request rather than surface this error directly.
var ErrCommandCenterBusy = errors.New("command-center session slot busy")

// commandCenterSlot is the single-slot mutex separating Command-Center
// sessions from the chat tab. Two booleans: held + queue depth surfaced.
var commandCenterSlot = &slotMutex{}

type slotMutex struct {
	mu    sync.Mutex
	held  bool
	queue int
}

func (s *slotMutex) tryAcquire() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.held {
		s.queue++
		return false
	}
	s.held = true
	return true
}
func (s *slotMutex) release() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.held = false
	if s.queue > 0 {
		s.queue--
	}
}

// QueueDepth returns the count of Command-Center send calls waiting for the
// slot. Surfaced to the widget for the "Queued · N ahead" badge.
func QueueDepth() int {
	commandCenterSlot.mu.Lock()
	defer commandCenterSlot.mu.Unlock()
	return commandCenterSlot.queue
}

// sanitisedEnv is the explicit Red-Team-Finding-1 allowlist. The child
// claude process inherits ONLY these vars; ANTHROPIC_*, OPENAI_*, CB_*,
// stale CLAUDE_CONFIG_DIR are all dropped.
//
// `CLAUDE_CONFIG_DIR` is set per spawn so the active Claude account at
// spawn time is locked in for the session lifetime even if the user
// switches accounts mid-stream.
func sanitisedEnv(configDir string) []string {
	allow := []string{"PATH", "HOME", "USER", "SHELL", "LANG", "LC_ALL"}
	env := make([]string, 0, len(allow)+2)
	for _, k := range allow {
		if v := os.Getenv(k); v != "" {
			env = append(env, k+"="+v)
		}
	}
	env = append(env, "TERM=dumb")
	if configDir != "" {
		env = append(env, "CLAUDE_CONFIG_DIR="+configDir)
	}
	return env
}

// Preflight verifies the installed `claude` CLI supports the flags Phase 4
// depends on. Returns the list of supported flags (subset of probe targets).
// Callers fall back to chat-tab mode if `--permission-mode` is absent.
func Preflight(binaryPath string) PreflightResult {
	out, err := exec.Command(binaryPath, "--help").CombinedOutput()
	if err != nil {
		return PreflightResult{Err: err}
	}
	text := strings.ToLower(string(out))
	return PreflightResult{
		PermissionMode:        strings.Contains(text, "--permission-mode"),
		AppendSystemPrompt:    strings.Contains(text, "--append-system-prompt"),
		DangerouslySkipPerms:  strings.Contains(text, "--dangerously-skip-permissions"),
		HelpText:              string(out),
	}
}

// PreflightResult reports which Phase-4-required flags the local claude CLI
// supports. Read once at app boot and cached.
type PreflightResult struct {
	Err                  error
	PermissionMode       bool
	AppendSystemPrompt   bool
	DangerouslySkipPerms bool
	HelpText             string
}
