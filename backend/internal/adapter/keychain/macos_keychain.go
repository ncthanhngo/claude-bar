// Package keychain wraps /usr/bin/security on macOS to read and write
// generic password entries that hold Claude Code OAuth credentials and
// local MCP connector secrets.
//
// All operations delegate to /usr/bin/security (Apple-signed system tool).
// Because it is universally trusted by macOS, it accesses keychain items
// without triggering per-app ACL permission dialogs — regardless of which
// application originally created the item.
package keychain

import (
	"bytes"
	"context"
	"errors"
	"os/exec"
	"strings"
	"time"
)

// migrateAddRetries bounds how many times we re-attempt the post-delete add.
// The delete already succeeded, so failing to re-add would orphan the
// caller's payload permanently — retry a small number of times before
// surfacing the error.
const migrateAddRetries = 3

// ErrNotFound is returned when the keychain has no entry for the given service.
var ErrNotFound = errors.New("keychain item not found")

// Keychain talks to /usr/bin/security.
type Keychain struct {
	service string
	account string
}

// New returns a Keychain bound to (service, account).
func New(service, account string) *Keychain {
	return &Keychain{service: service, account: account}
}

// Read returns the password payload for this (service, account).
func (k *Keychain) Read(ctx context.Context) (string, error) {
	cmd := exec.CommandContext(ctx,
		"/usr/bin/security",
		"find-generic-password",
		"-s", k.service,
		"-a", k.account,
		"-w",
	)
	var out, errOut bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errOut
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) && ee.ExitCode() == 44 {
			return "", ErrNotFound
		}
		return "", &Error{Op: "read", Stderr: errOut.String(), Err: err}
	}
	return strings.TrimRight(out.String(), "\n"), nil
}

// Write upserts the password for this (service, account).
// The -U flag updates an existing item in-place (preserving the item's ACL)
// or creates a new one if absent. Using /usr/bin/security means the operation
// is never subject to per-app ACL prompts.
func (k *Keychain) Write(ctx context.Context, payload string) error {
	cmd := exec.CommandContext(ctx,
		"/usr/bin/security",
		"add-generic-password",
		"-U",
		"-s", k.service,
		"-a", k.account,
		"-w", payload,
	)
	var errOut bytes.Buffer
	cmd.Stderr = &errOut
	if err := cmd.Run(); err != nil {
		return &Error{Op: "write", Stderr: errOut.String(), Err: err}
	}
	return nil
}

// Migrate removes the item and recreates it without a restrictive ACL.
// Call this immediately after a successful Read on an item that triggered a
// macOS password dialog. The delete step does not access the secret data so
// it does not show a second dialog. The fresh add-generic-password (no -U,
// no -T trusted-app flag) creates an item any process can read without prompting.
//
// Because delete happens before add, a failed add would orphan the caller's
// payload (the only in-memory copy of the credential) permanently — forcing a
// re-login on that account. Retry the add a few times with a short backoff
// to absorb transient Keychain unavailability (locked keychain race, security
// CLI throttling) before giving up.
func (k *Keychain) Migrate(ctx context.Context, payload string) error {
	del := exec.CommandContext(ctx,
		"/usr/bin/security",
		"delete-generic-password",
		"-s", k.service,
		"-a", k.account,
	)
	_ = del.Run() // ignore: item may already be gone

	var lastErr error
	var lastStderr string
	for attempt := 0; attempt < migrateAddRetries; attempt++ {
		add := exec.CommandContext(ctx,
			"/usr/bin/security",
			"add-generic-password",
			"-s", k.service,
			"-a", k.account,
			"-w", payload,
		)
		var errOut bytes.Buffer
		add.Stderr = &errOut
		if err := add.Run(); err == nil {
			return nil
		} else {
			lastErr = err
			lastStderr = errOut.String()
		}
		select {
		case <-ctx.Done():
			return &Error{Op: "migrate", Stderr: lastStderr, Err: ctx.Err()}
		case <-time.After(time.Duration(100*(attempt+1)) * time.Millisecond):
		}
	}
	return &Error{Op: "migrate", Stderr: lastStderr, Err: lastErr}
}

// Delete removes the entry. No error if absent.
func (k *Keychain) Delete(ctx context.Context) error {
	cmd := exec.CommandContext(ctx,
		"/usr/bin/security",
		"delete-generic-password",
		"-s", k.service,
		"-a", k.account,
	)
	var errOut bytes.Buffer
	cmd.Stderr = &errOut
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) && ee.ExitCode() == 44 {
			return nil
		}
		return &Error{Op: "delete", Stderr: errOut.String(), Err: err}
	}
	return nil
}

// Error carries the security CLI stderr for diagnostics.
type Error struct {
	Op     string
	Stderr string
	Err    error
}

func (e *Error) Error() string {
	if e.Stderr != "" {
		return "keychain " + e.Op + ": " + strings.TrimSpace(e.Stderr)
	}
	return "keychain " + e.Op + ": " + e.Err.Error()
}

func (e *Error) Unwrap() error { return e.Err }
