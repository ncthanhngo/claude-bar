package ssh

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// ExecResult is the output of a one-shot `ssh host -- <cmd>` call.
type ExecResult struct {
	Stdout    string `json:"stdout"`
	Stderr    string `json:"stderr"`
	ExitCode  int    `json:"exitCode"`
	DurationMs int64 `json:"durationMs"`
}

// Exec runs a single command against a tracked host. The command is passed as
// a single argv element to `ssh host -- <cmd>` — the local `ssh` client does
// not tokenize it. Metachar injection from the LLM was already blocked at
// the gate by ClassifyCmd; the same string the user approved is what runs.
//
// timeout caps the wall-clock duration via context.WithTimeout.
func Exec(ctx context.Context, host TrackedHost, cmd string, timeout time.Duration) (*ExecResult, error) {
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	args := sshArgs(host)
	args = append(args, "--", cmd)
	start := time.Now()
	cc := exec.CommandContext(ctx, "ssh", args...)
	var stdout, stderr bytes.Buffer
	cc.Stdout = &stdout
	cc.Stderr = &stderr
	err := cc.Run()
	res := &ExecResult{
		Stdout:     stdout.String(),
		Stderr:     stderr.String(),
		DurationMs: time.Since(start).Milliseconds(),
		ExitCode:   0,
	}
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			res.ExitCode = ee.ExitCode()
			return res, nil
		}
		if ctx.Err() == context.DeadlineExceeded {
			res.ExitCode = 124 // GNU timeout convention
			res.Stderr = strings.TrimSpace(res.Stderr+"\nssh exec timed out")
			return res, nil
		}
		return res, fmt.Errorf("ssh exec: %w", err)
	}
	return res, nil
}

// Tail runs `tail -n N -f <path>` against a host with a hard wall-clock
// follow window (follow_seconds is clamped to ≤ 60). Returns whatever lines
// arrived before the window elapsed or the context cancelled.
func Tail(ctx context.Context, host TrackedHost, path string, lines, followSeconds int) (*ExecResult, error) {
	if lines <= 0 {
		lines = 100
	}
	if lines > 5000 {
		lines = 5000
	}
	if followSeconds < 0 {
		followSeconds = 0
	}
	if followSeconds > 60 {
		followSeconds = 60
	}

	tailCmd := fmt.Sprintf("tail -n %d", lines)
	if followSeconds > 0 {
		tailCmd = fmt.Sprintf("timeout %d tail -n %d -f", followSeconds, lines)
	}
	tailCmd += " " + shellQuote(path)

	timeout := 10 * time.Second
	if followSeconds > 0 {
		timeout = time.Duration(followSeconds+5) * time.Second
	}
	return Exec(ctx, host, tailCmd, timeout)
}

// sshArgs builds the standard option set for connecting to a tracked host.
// Skips features we don't need (X11, agent forwarding) for safety.
func sshArgs(h TrackedHost) []string {
	args := []string{
		"-o", "BatchMode=yes",
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "ConnectTimeout=10",
		"-o", "ServerAliveInterval=15",
	}
	if h.Port > 0 {
		args = append(args, "-p", fmt.Sprintf("%d", h.Port))
	}
	if h.IdentityFile != "" {
		args = append(args, "-i", h.IdentityFile)
	}
	if h.JumpHost != "" {
		args = append(args, "-J", h.JumpHost)
	}
	target := h.Name
	if h.HostName != "" {
		target = h.HostName
		if h.User != "" {
			target = h.User + "@" + target
		}
	}
	args = append(args, target)
	return args
}

func shellQuote(s string) string {
	if s == "" {
		return "''"
	}
	if !strings.ContainsAny(s, " \t\"'`$;&|<>()") {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
