package ssh

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// ExecResult is the output of a one-shot `ssh host -- <cmd>` call.
type ExecResult struct {
	Stdout     string `json:"stdout"`
	Stderr     string `json:"stderr"`
	ExitCode   int    `json:"exitCode"`
	DurationMs int64  `json:"durationMs"`
}

// ActiveControlMaster, when set, lets Exec reuse a persistent ssh
// ControlMaster socket per host instead of opening a fresh connection per
// call. nil falls back to one-shot ssh.
var ActiveControlMaster *ControlMaster

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

	// Password auth (if configured): fed non-interactively via SSH_ASKPASS so
	// the secret never lands in argv. ssh tries password then the key
	// (PreferredAuthentications below), so a missing/wrong password falls back
	// to key-based auth automatically.
	password := ""
	if host.PasswordAuth {
		password = ReadPassword(ctx, host.Name)
	}
	passwordMode := password != ""

	args := []string{}
	// Lazily open a ControlMaster so the 1st call eats the auth round-trip and
	// every subsequent call reuses the same TCP connection. Skipped in
	// password mode — the master would open without the askpass env and fail.
	if ActiveControlMaster != nil && !passwordMode {
		if sock, err := ActiveControlMaster.Open(ctx, host); err == nil {
			args = append(args, "-S", sock)
		}
	}
	args = append(args, sshArgs(host, passwordMode)...)
	args = append(args, "--", cmd)
	start := time.Now()
	cc := exec.CommandContext(ctx, "ssh", args...)
	var stdout, stderr bytes.Buffer
	cc.Stdout = &stdout
	cc.Stderr = &stderr
	if passwordMode {
		askpass, cleanup, aerr := writeAskpassScript()
		if aerr == nil {
			defer cleanup()
			cc.Env = append(os.Environ(),
				"SSH_ASKPASS="+askpass,
				"SSH_ASKPASS_REQUIRE=force",
				"DISPLAY=:0",
				"CSW_SSH_PASSWORD="+password,
			)
		}
	}
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
			res.Stderr = strings.TrimSpace(res.Stderr + "\nssh exec timed out")
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

// ReadFile reads up to maxBytes from the head of a remote file via
// `head -c N -- path`. Returns whatever bytes the remote sent before the
// limit was reached. Use this instead of Exec("cat …") so the byte cap is
// enforced server-side and large files cannot blow up the agent context.
func ReadFile(ctx context.Context, host TrackedHost, path string, maxBytes int) (*ExecResult, error) {
	if maxBytes <= 0 {
		maxBytes = 100 * 1024 // 100 KiB default
	}
	if maxBytes > 5*1024*1024 {
		maxBytes = 5 * 1024 * 1024 // 5 MiB cap
	}
	cmd := fmt.Sprintf("head -c %d -- %s", maxBytes, shellQuote(path))
	return Exec(ctx, host, cmd, 30*time.Second)
}

// sshArgs builds the standard option set for connecting to a tracked host.
// Skips features we don't need (X11, agent forwarding) for safety.
//
// passwordMode drops BatchMode (which would block the askpass prompt) and
// orders password before publickey so ssh tries the stored password first and
// falls back to the key when it's absent or rejected.
func sshArgs(h TrackedHost, passwordMode bool) []string {
	args := []string{
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "ConnectTimeout=10",
		"-o", "ServerAliveInterval=15",
	}
	if passwordMode {
		args = append(args,
			"-o", "PreferredAuthentications=password,publickey",
			"-o", "PubkeyAuthentication=yes",
			"-o", "NumberOfPasswordPrompts=1",
		)
	} else {
		args = append(args, "-o", "BatchMode=yes")
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

// RemoveKnownHost drops a host's entry from the local ~/.ssh/known_hosts via
// `ssh-keygen -R`. After a host-key change this lets StrictHostKeyChecking=
// accept-new re-pin the new key on the next connection — the in-app "trust the
// new key" action. Local-only; touches no remote.
func RemoveKnownHost(ctx context.Context, target string) error {
	cmd := exec.CommandContext(ctx, "ssh-keygen", "-R", target)
	var errOut bytes.Buffer
	cmd.Stderr = &errOut
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("ssh-keygen -R %s: %w: %s", target, err, strings.TrimSpace(errOut.String()))
	}
	return nil
}

// writeAskpassScript drops a tiny 0700 helper that prints $CSW_SSH_PASSWORD.
// The script holds NO secret — the password travels only in the ssh child's
// environment — so a stray copy on disk leaks nothing. Caller must run cleanup.
func writeAskpassScript() (path string, cleanup func(), err error) {
	f, err := os.CreateTemp("", "csw-askpass-*.sh")
	if err != nil {
		return "", nil, err
	}
	if _, err := f.WriteString("#!/bin/sh\nprintf '%s\\n' \"$CSW_SSH_PASSWORD\"\n"); err != nil {
		f.Close()
		os.Remove(f.Name())
		return "", nil, err
	}
	f.Close()
	if err := os.Chmod(f.Name(), 0o700); err != nil {
		os.Remove(f.Name())
		return "", nil, err
	}
	return f.Name(), func() { os.Remove(f.Name()) }, nil
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
