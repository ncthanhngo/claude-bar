package ssh

import (
	"regexp"
	"strings"
)

// Risk mirrors mcp.Risk levels; ssh adapter declares its own to avoid an
// import cycle. Callers map to mcp.Risk at the gateway boundary.
type Risk int

const (
	RiskLow Risk = iota
	RiskMedium
	RiskDestructive
)

// ClassifyCmd produces a Risk level for a raw command string a user / LLM
// wants to run on a remote host.
//
// Defence-in-depth (Red-Team Finding 6):
//
//  1. Metachar scan — any shell metacharacter / chain operator / command
//     substitution / base64 marker forces RiskDestructive regardless of what
//     the command looks like. `uptime; rm -rf /` no longer slips through as
//     Low.
//  2. Strict allowlist — only fully matching single-token reads qualify Low.
//  3. Curated table — prefixes by behaviour family.
//  4. `sudo` bumps one risk level (Low→Medium, Medium→Destructive).
//  5. Unknown commands default Medium, never Low.
func ClassifyCmd(cmd string) Risk {
	c := strings.TrimSpace(cmd)
	if c == "" {
		return RiskMedium
	}
	if hasMetachar(c) {
		return RiskDestructive
	}

	bumpForSudo := false
	if strings.HasPrefix(c, "sudo ") || c == "sudo" {
		bumpForSudo = true
		c = strings.TrimSpace(strings.TrimPrefix(c, "sudo"))
	}

	risk := classifyClean(c)
	if bumpForSudo {
		risk = bumpRisk(risk)
	}
	return risk
}

// hasMetachar returns true when c contains any shell metacharacter or
// chain/redirect / substitution / base64-shaped marker. Any of these means
// the command is not the simple `cmd args…` shape we can safely classify.
func hasMetachar(c string) bool {
	// Quick reject: control-char / newline.
	for _, r := range c {
		if r == '\n' || r == '\r' || r == '\x00' {
			return true
		}
	}
	// Explicit metachar set. Note: `>`, `<`, `>>`, `<<` covered by '<' / '>'
	// substrings. Backtick + `$(`, `${`, redirects, pipes, all chain forms.
	bad := []string{";", "&", "|", "`", "$(", "${", ">", "<"}
	for _, b := range bad {
		if strings.Contains(c, b) {
			return true
		}
	}
	// base64 padding marker — at least 16 contiguous base64 chars then `==`.
	if b64ish.MatchString(c) {
		return true
	}
	return false
}

var b64ish = regexp.MustCompile(`[A-Za-z0-9+/]{16,}==`)

// strictLowAllowlist exactly matches the entire trimmed command.
var strictLowAllowlist = map[string]bool{
	"uptime": true, "whoami": true, "hostname": true, "date": true,
	"id": true, "pwd": true, "df": true, "df -h": true,
	"free": true, "free -m": true, "free -h": true,
}

// medFamilies are command prefixes (head token) classified by behaviour.
// Reads are Low if no destructive flag follows; writes are Medium.
var readFamilies = map[string]bool{
	"tail":       true,
	"cat":        true,
	"ls":         true,
	"grep":       true,
	"ps":         true,
	"journalctl": true,
	"head":       true,
	"wc":         true,
	"stat":       true,
	"du":         true,
	"who":        true,
	"top":        true,
	"htop":       true,
	"netstat":    true,
	"ss":         true,
	"ip":         true,
	"hostname":   true,
	"docker":     true, // refined below
	"kubectl":    true, // refined below
	"systemctl":  true, // refined below
	"git":        true, // refined below
}

func classifyClean(c string) Risk {
	if strictLowAllowlist[c] {
		return RiskLow
	}
	head, rest := splitHead(c)
	// Family prefixes like `mkfs.ext4`, `apt-get`, `kubectl-foo` get
	// reduced to their root before lookup so the destructive `mkfs.*` /
	// `apt*` patterns trip correctly.
	if i := strings.IndexAny(head, ".-"); i > 0 {
		switch head[:i] {
		case "mkfs":
			return RiskDestructive
		case "apt":
			return RiskMedium
		}
	}
	switch head {
	case "":
		return RiskMedium
	case "rm", "dd", "shutdown", "reboot", "halt", "poweroff":
		return RiskDestructive
	case "kill":
		// `kill -9 1` is destructive; otherwise Medium.
		if strings.Contains(rest, "-9") && strings.Contains(rest, " 1 ") {
			return RiskDestructive
		}
		return RiskMedium
	case "docker":
		return classifyDocker(rest)
	case "kubectl":
		return classifyKubectl(rest)
	case "systemctl":
		return classifySystemctl(rest)
	case "git":
		return classifyGit(rest)
	}

	if readFamilies[head] {
		return RiskLow
	}
	return RiskMedium
}

func classifyDocker(rest string) Risk {
	head, _ := splitHead(rest)
	switch head {
	case "ps", "logs", "inspect", "stats", "images", "history", "top", "version":
		return RiskLow
	case "restart", "start", "stop", "pause", "unpause", "exec", "run":
		return RiskMedium
	case "rm", "rmi", "kill", "system", "container", "volume", "network":
		// `docker rm`/`rmi`/`kill` always destructive when followed by an id.
		return RiskDestructive
	}
	return RiskMedium
}

func classifyKubectl(rest string) Risk {
	head, _ := splitHead(rest)
	switch head {
	case "get", "describe", "logs", "top", "version", "config":
		return RiskLow
	case "apply", "annotate", "label", "rollout", "scale", "patch", "create", "edit":
		return RiskMedium
	case "delete", "drain", "cordon", "exec", "replace":
		return RiskDestructive
	}
	return RiskMedium
}

func classifySystemctl(rest string) Risk {
	head, _ := splitHead(rest)
	switch head {
	case "status", "is-active", "is-enabled", "show", "cat", "list-units", "list-timers":
		return RiskLow
	case "restart", "start", "reload", "enable", "disable", "mask", "unmask":
		return RiskMedium
	case "stop", "kill", "isolate", "poweroff", "reboot", "halt":
		return RiskDestructive
	}
	return RiskMedium
}

func classifyGit(rest string) Risk {
	head, _ := splitHead(rest)
	switch head {
	case "status", "log", "show", "diff", "branch", "remote", "config":
		return RiskLow
	case "pull", "fetch", "push", "checkout", "switch", "merge", "rebase", "stash", "commit":
		return RiskMedium
	case "reset", "clean", "rm":
		return RiskDestructive
	}
	return RiskMedium
}

func splitHead(s string) (head, rest string) {
	s = strings.TrimLeft(s, " \t")
	idx := strings.IndexAny(s, " \t")
	if idx < 0 {
		return s, ""
	}
	return s[:idx], strings.TrimLeft(s[idx:], " \t")
}

func bumpRisk(r Risk) Risk {
	switch r {
	case RiskLow:
		return RiskMedium
	case RiskMedium:
		return RiskDestructive
	default:
		return RiskDestructive
	}
}
