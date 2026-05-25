// Package bwcli wraps the Bitwarden `bw` CLI for the Claude Bar Bitwarden
// MCP (Phase 9). All exec calls inject BW_SESSION via env, never argv. No
// command builder accepts user-supplied flags — every public function maps
// to one bw subcommand we trust.
package bwcli

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// Runner is the boundary so tests can substitute a fake bw. The wrapper
// uses BwRunner for `bw` shell-outs and falls back to ExecRunner if nil.
type Runner interface {
	Run(ctx context.Context, args []string, env map[string]string) (stdout string, stderr string, exitCode int, err error)
}

// ExecRunner is the production Runner — invokes `bw` from PATH.
type ExecRunner struct {
	BinaryPath string // default: "bw" on PATH
}

func (r ExecRunner) Run(ctx context.Context, args []string, env map[string]string) (string, string, int, error) {
	bin := r.BinaryPath
	if bin == "" {
		bin = "bw"
	}
	cmd := exec.CommandContext(ctx, bin, args...)
	if len(env) > 0 {
		base := []string{}
		for _, e := range []string{"PATH", "HOME", "USER"} {
			if v := envValue(e); v != "" {
				base = append(base, e+"="+v)
			}
		}
		for k, v := range env {
			base = append(base, k+"="+v)
		}
		cmd.Env = base
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	exit := 0
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			exit = ee.ExitCode()
			err = nil
		}
	}
	return stdout.String(), stderr.String(), exit, err
}

func envValue(key string) string {
	for _, kv := range cmdEnvLookup {
		if strings.HasPrefix(kv, key+"=") {
			return strings.TrimPrefix(kv, key+"=")
		}
	}
	return ""
}

// cmdEnvLookup is filled by the binary's package init; tests override.
var cmdEnvLookup = []string{}

// ItemSummary is the redacted shape returned by Search. Secret material
// (password, totp, notes, hidden custom fields) is intentionally absent.
type ItemSummary struct {
	ID     string   `json:"id"`
	Name   string   `json:"name"`
	Folder string   `json:"folder,omitempty"`
	Type   string   `json:"type,omitempty"`
	URIs   []string `json:"uris,omitempty"`
}

// Item is the per-item shape returned by Get. When reveal=false, the secret
// fields are stripped server-side before crossing the MCP boundary.
type Item struct {
	ID       string            `json:"id"`
	Name     string            `json:"name"`
	Folder   string            `json:"folder,omitempty"`
	URIs     []string          `json:"uris,omitempty"`
	Username string            `json:"username,omitempty"`
	Password string            `json:"password,omitempty"`
	TOTP     string            `json:"totp,omitempty"`
	Notes    string            `json:"notes,omitempty"`
	Fields   map[string]string `json:"fields,omitempty"`
}

// Folder is the redacted shape returned by ListFolders. Folder names are
// not secret material per se, but the structure of a vault can hint at
// what the user stores — so the surface is still gated.
type Folder struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// ListFolders returns every folder the user has access to. `bw list
// folders` always includes the implicit "No Folder" entry with a null
// ID — we surface it as id="" so the agent can filter on it cleanly.
func ListFolders(ctx context.Context, r Runner, session string) ([]Folder, error) {
	if r == nil {
		r = ExecRunner{}
	}
	stdout, stderr, code, err := r.Run(ctx, []string{"list", "folders"}, map[string]string{"BW_SESSION": session})
	if err != nil {
		return nil, fmt.Errorf("bw list folders: %w", err)
	}
	if code != 0 {
		return nil, fmt.Errorf("bw list folders exit %d: %s", code, strings.TrimSpace(stderr))
	}
	return parseFolders(stdout), nil
}

// Search returns redacted item summaries that match q. Empty q returns
// nothing (we never want a "give me every secret" path).
func Search(ctx context.Context, r Runner, session, q string) ([]ItemSummary, error) {
	if r == nil {
		r = ExecRunner{}
	}
	if strings.TrimSpace(q) == "" {
		return nil, errors.New("query required")
	}
	args := []string{"list", "items", "--search", q}
	stdout, stderr, code, err := r.Run(ctx, args, map[string]string{"BW_SESSION": session})
	if err != nil {
		return nil, fmt.Errorf("bw search: %w", err)
	}
	if code != 0 {
		return nil, fmt.Errorf("bw search exit %d: %s", code, strings.TrimSpace(stderr))
	}
	return parseSummaries(stdout), nil
}

// Get returns one full item. When reveal is false, password/totp/notes/
// hidden custom fields are zeroed before returning so the caller can hand
// the result to the LLM safely.
func Get(ctx context.Context, r Runner, session, id string, reveal bool) (*Item, error) {
	if r == nil {
		r = ExecRunner{}
	}
	if id == "" {
		return nil, errors.New("id required")
	}
	args := []string{"get", "item", id}
	stdout, stderr, code, err := r.Run(ctx, args, map[string]string{"BW_SESSION": session})
	if err != nil {
		return nil, fmt.Errorf("bw get: %w", err)
	}
	if code != 0 {
		return nil, fmt.Errorf("bw get exit %d: %s", code, strings.TrimSpace(stderr))
	}
	item, err := parseItem(stdout)
	if err != nil {
		return nil, err
	}
	if !reveal {
		item.Password = ""
		item.TOTP = ""
		item.Notes = ""
		// Strip hidden custom fields. bw exposes a `linkedId`/`type` per
		// field; type 1 = hidden. We don't model that here — when reveal is
		// false, clear *all* custom fields to be safe.
		item.Fields = nil
	}
	return item, nil
}
