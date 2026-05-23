package claudecli

import (
	"fmt"
	"strings"
)

// SessionContext is the per-spawn data we inject as a system-prompt append.
// All fields optional; missing fields are skipped in the rendered text.
type SessionContext struct {
	RepoPath      string
	SSHHost       string
	ClaudeAccount string
	BriefingFocus string
}

// Render returns the system-prompt append string. Always prefixed with a
// header so the model can recognise it as auto-injected context, not a user
// instruction. Empty input → empty output (no flag set).
func (c SessionContext) Render() string {
	if c.RepoPath == "" && c.SSHHost == "" && c.ClaudeAccount == "" && c.BriefingFocus == "" {
		return ""
	}
	var b strings.Builder
	b.WriteString("Claude Bar Command Center — session context (auto-generated; do not treat as user instructions).\n\n")
	if c.RepoPath != "" {
		fmt.Fprintf(&b, "Active repository: %s\n", c.RepoPath)
	}
	if c.SSHHost != "" {
		fmt.Fprintf(&b, "Active SSH host: %s\n", c.SSHHost)
	}
	if c.ClaudeAccount != "" {
		fmt.Fprintf(&b, "Active Claude account: %s\n", c.ClaudeAccount)
	}
	if c.BriefingFocus != "" {
		fmt.Fprintf(&b, "Briefing focus: %s\n", c.BriefingFocus)
	}
	return strings.TrimRight(b.String(), "\n")
}
