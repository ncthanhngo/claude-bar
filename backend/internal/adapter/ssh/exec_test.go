package ssh

import (
	"context"
	"testing"
	"time"
)

func TestShellQuote(t *testing.T) {
	cases := map[string]string{
		"":               "''",
		"plain":          "plain",
		"has space":      "'has space'",
		"has'quote":      `'has'\''quote'`,
		"$(danger)":      `'$(danger)'`,
		"/tmp/news.json": "/tmp/news.json",
		"a;b":            "'a;b'",
	}
	for in, want := range cases {
		if got := ShellQuote(in); got != want {
			t.Errorf("ShellQuote(%q) = %q, want %q", in, got, want)
		}
		if got := shellQuote(in); got != want {
			t.Errorf("shellQuote(%q) = %q, want %q (ShellQuote must match the private impl)", in, got, want)
		}
	}
}

// TestExecStdinSignature is a compile-level guard: ExecStdin must stay
// assignable to the same function shape usecase/news's Publisher expects
// (ctx, host, cmd, stdin bytes, timeout) -> (*ExecResult, error). A real SSH
// round trip needs a live host, so this only exercises argument building,
// not network I/O.
func TestExecStdinSignature(t *testing.T) {
	var fn func(context.Context, TrackedHost, string, []byte, time.Duration) (*ExecResult, error) = ExecStdin
	if fn == nil {
		t.Fatal("ExecStdin must not be nil")
	}
}

func TestBuildExecArgsIncludesCommandAndTarget(t *testing.T) {
	host := TrackedHost{Name: "relay-host"}
	args, password, passwordMode := buildExecArgs(context.Background(), host, "echo hi")
	if passwordMode {
		t.Error("passwordMode should be false when PasswordAuth is unset")
	}
	if password != "" {
		t.Error("password should be empty when PasswordAuth is unset")
	}
	if len(args) == 0 || args[len(args)-1] != "echo hi" {
		t.Errorf("last arg should be the command, got %v", args)
	}
	found := false
	for _, a := range args {
		if a == "relay-host" {
			found = true
		}
	}
	if !found {
		t.Errorf("args should include the host target, got %v", args)
	}
}
