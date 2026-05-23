// Package ssh contains the SSH adapter for the Claude Bar SSH server manager
// (Phase 3 of the Command Center plan).
package ssh

import (
	"bufio"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// HostEntry is one Host stanza from ~/.ssh/config, normalised. Extra options
// the parser doesn't model are preserved verbatim so round-tripping doesn't
// lose user customisation.
type HostEntry struct {
	Name         string            `json:"name"`
	HostName     string            `json:"hostName,omitempty"`
	Port         int               `json:"port,omitempty"`
	User         string            `json:"user,omitempty"`
	IdentityFile string            `json:"identityFile,omitempty"`
	JumpHost     string            `json:"jumpHost,omitempty"`
	Extra        map[string]string `json:"extra,omitempty"`
}

// ParseSSHConfig reads `~/.ssh/config` and returns the Host stanzas in the
// order they appear. Wildcard hosts (`*`) and the special `Host *` block are
// returned as well; callers filter them out by checking `IsWildcard()`.
//
// Honours `Include` directives by transitively parsing included files. Cycles
// are broken with a visited set.
func ParseSSHConfig(path string) ([]HostEntry, error) {
	return parseConfigFile(path, map[string]bool{})
}

// IsWildcard reports whether the host name contains glob metacharacters.
func (h HostEntry) IsWildcard() bool {
	return strings.ContainsAny(h.Name, "*?!")
}

func parseConfigFile(path string, visited map[string]bool) ([]HostEntry, error) {
	abs, err := expandUser(path)
	if err != nil {
		return nil, err
	}
	if visited[abs] {
		return nil, nil
	}
	visited[abs] = true

	f, err := os.Open(abs)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()

	return parseConfigReader(f, filepath.Dir(abs), visited)
}

func parseConfigReader(r io.Reader, baseDir string, visited map[string]bool) ([]HostEntry, error) {
	var out []HostEntry
	var current *HostEntry
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 4096), 256*1024)

	flush := func() {
		if current == nil {
			return
		}
		out = append(out, *current)
		current = nil
	}

	for scanner.Scan() {
		raw := scanner.Text()
		line := strings.TrimSpace(stripComment(raw))
		if line == "" {
			continue
		}
		key, value := splitKV(line)
		if key == "" {
			continue
		}
		switch strings.ToLower(key) {
		case "host":
			flush()
			current = &HostEntry{Name: value, Extra: map[string]string{}}
		case "include":
			expanded := value
			if !filepath.IsAbs(expanded) {
				expanded = filepath.Join(baseDir, expanded)
			}
			children, err := parseConfigFile(expanded, visited)
			if err != nil {
				return nil, err
			}
			out = append(out, children...)
		default:
			if current == nil {
				continue
			}
			applyOption(current, key, value)
		}
	}
	flush()
	if err := scanner.Err(); err != nil {
		return out, err
	}
	return out, nil
}

func applyOption(h *HostEntry, key, value string) {
	switch strings.ToLower(key) {
	case "hostname":
		h.HostName = value
	case "port":
		if n, ok := atoiSafe(value); ok {
			h.Port = n
		}
	case "user":
		h.User = value
	case "identityfile":
		h.IdentityFile = value
	case "proxyjump":
		h.JumpHost = value
	default:
		if h.Extra == nil {
			h.Extra = map[string]string{}
		}
		h.Extra[key] = value
	}
}

func splitKV(line string) (string, string) {
	// SSH config allows either `key value` or `key=value`. Match either.
	if idx := strings.IndexAny(line, " \t="); idx > 0 {
		key := strings.TrimSpace(line[:idx])
		val := strings.TrimSpace(line[idx+1:])
		val = strings.TrimLeft(val, "=")
		val = strings.TrimSpace(val)
		val = strings.Trim(val, "\"")
		return key, val
	}
	return "", ""
}

func stripComment(s string) string {
	// Comments only at start of a non-quoted token. Cheap approximation:
	// drop any segment after a # that follows whitespace, but not inside
	// quoted values.
	if !strings.Contains(s, "#") {
		return s
	}
	inQuote := false
	for i, r := range s {
		if r == '"' {
			inQuote = !inQuote
			continue
		}
		if r == '#' && !inQuote && (i == 0 || s[i-1] == ' ' || s[i-1] == '\t') {
			return s[:i]
		}
	}
	return s
}

func expandUser(path string) (string, error) {
	if !strings.HasPrefix(path, "~") {
		return path, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return path, err
	}
	return filepath.Join(home, strings.TrimPrefix(path, "~")), nil
}

func atoiSafe(s string) (int, bool) {
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
	}
	if s == "" {
		return 0, false
	}
	return n, true
}
