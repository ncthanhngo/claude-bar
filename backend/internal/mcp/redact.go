// Package mcp hosts the local MCP gateway that bridges Claude Code to
// per-account connector credentials stored in the macOS Keychain.
package mcp

import "regexp"

// tokenPatterns matches values that look like provider tokens. The list is
// intentionally narrow — only patterns with low false-positive rates are
// included so legitimate text in tool responses is not mangled.
var tokenPatterns = []*regexp.Regexp{
	regexp.MustCompile(`xox[abeprs](?:\.[a-z0-9]+)?-[A-Za-z0-9._\-]{10,}`),   // Slack (incl. rotation/refresh tokens xoxe.*)
	regexp.MustCompile(`pk_[0-9]+_[A-Z0-9]{20,}`),                            // ClickUp personal
	regexp.MustCompile(`ya29\.[A-Za-z0-9_\-]+`),                              // Google access
	regexp.MustCompile(`1//[A-Za-z0-9_\-]{30,}`),                             // Google refresh
	regexp.MustCompile(`(?i)bearer\s+[A-Za-z0-9._\-]+`),                      // Authorization headers
	regexp.MustCompile(`(?i)"(refresh_token|access_token|refresh_secret|access_secret|client_secret)"\s*:\s*"[^"]+"`),// JSON secret fields
}

// Redact replaces every matched token-shaped substring with [REDACTED].
// Designed for log output and error messages crossing the backend/widget boundary.
func Redact(s string) string {
	for _, re := range tokenPatterns {
		s = re.ReplaceAllString(s, "[REDACTED]")
	}
	return s
}
