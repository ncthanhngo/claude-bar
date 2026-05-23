// Package repomap walks user-chosen root directories looking for git repos
// and maps their `origin` remote URL → local path. The result lets the
// Command Center "Ask Claude" buttons resolve a PR/issue source repo back
// to a checkout on disk without prompting every time.
package repomap

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Entry is one origin → local path pair.
type Entry struct {
	Origin     string    `json:"origin"`     // canonical origin URL (normalised)
	LocalPath  string    `json:"localPath"`
	DiscoveredAt time.Time `json:"discoveredAt"`
}

// Map is the persisted file shape.
type Map struct {
	UpdatedAt time.Time `json:"updatedAt"`
	Roots     []string  `json:"roots"`
	Entries   []Entry   `json:"entries"`
}

// Scanner walks roots, parses git/config files, and builds the map.
type Scanner struct {
	Roots    []string // e.g. ~/Project, ~/dev, ~/Code, ~/src
	MaxDepth int      // typically 2; 0 = unlimited
}

// Scan returns a populated Map (no on-disk side effect). Use Save() to
// persist to a JSON file under WidgetDataDir.
func (s Scanner) Scan() (*Map, error) {
	if len(s.Roots) == 0 {
		return nil, errors.New("repomap: no roots configured")
	}
	maxDepth := s.MaxDepth
	if maxDepth <= 0 {
		maxDepth = 2
	}
	m := &Map{
		UpdatedAt: time.Now().UTC(),
		Roots:     s.Roots,
	}
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, root := range s.Roots {
		root := expandUser(root)
		wg.Add(1)
		go func() {
			defer wg.Done()
			entries := walkRoot(root, maxDepth)
			mu.Lock()
			m.Entries = append(m.Entries, entries...)
			mu.Unlock()
		}()
	}
	wg.Wait()
	return m, nil
}

// Save persists the map to path with 0600 perms; parent dir gets 0700.
func (m *Map) Save(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Load reads a previously-saved Map. Returns (nil, nil) if the file is
// absent (caller treats as empty).
func Load(path string) (*Map, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var m Map
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	return &m, nil
}

// Lookup returns the local path for an origin URL, or empty when unknown.
// Origin is normalised before comparison.
func (m *Map) Lookup(origin string) string {
	norm := NormaliseOrigin(origin)
	for _, e := range m.Entries {
		if NormaliseOrigin(e.Origin) == norm {
			return e.LocalPath
		}
	}
	return ""
}

// walkRoot recurses up to maxDepth folders below root and yields entries
// for any directory containing a .git/config file.
func walkRoot(root string, maxDepth int) []Entry {
	var out []Entry
	walk(root, 0, maxDepth, func(path string) {
		gitDir := filepath.Join(path, ".git")
		info, err := os.Stat(gitDir)
		if err != nil || !info.IsDir() {
			return
		}
		origin := readOrigin(filepath.Join(gitDir, "config"))
		if origin == "" {
			return
		}
		out = append(out, Entry{
			Origin:       origin,
			LocalPath:    path,
			DiscoveredAt: time.Now().UTC(),
		})
	})
	return out
}

func walk(dir string, depth, max int, visit func(string)) {
	visit(dir)
	if depth >= max {
		return
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		// Skip well-known noise.
		switch e.Name() {
		case "node_modules", "vendor", "Pods", "build", "target", ".next", "dist":
			continue
		}
		walk(filepath.Join(dir, e.Name()), depth+1, max, visit)
	}
}

var urlRe = regexp.MustCompile(`url\s*=\s*(.+)$`)

func readOrigin(configPath string) string {
	f, err := os.Open(configPath)
	if err != nil {
		return ""
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	inOrigin := false
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "[remote ") {
			inOrigin = strings.Contains(line, `"origin"`)
			continue
		}
		if strings.HasPrefix(line, "[") {
			inOrigin = false
			continue
		}
		if inOrigin {
			if m := urlRe.FindStringSubmatch(line); len(m) == 2 {
				return strings.TrimSpace(m[1])
			}
		}
	}
	return ""
}

// NormaliseOrigin folds `git@github.com:owner/repo.git`, `https://...`, and
// `ssh://git@...` into a comparable form (`github.com/owner/repo`).
func NormaliseOrigin(url string) string {
	s := strings.TrimSpace(url)
	s = strings.TrimSuffix(s, ".git")
	s = strings.TrimSuffix(s, "/")
	// ssh shorthand: git@github.com:owner/repo
	if strings.HasPrefix(s, "git@") {
		if idx := strings.Index(s, ":"); idx > 0 {
			host := s[len("git@"):idx]
			path := s[idx+1:]
			return host + "/" + path
		}
	}
	// ssh://git@host/owner/repo
	if strings.HasPrefix(s, "ssh://") {
		s = strings.TrimPrefix(s, "ssh://")
		s = strings.TrimPrefix(s, "git@")
	}
	// https:// or http://
	for _, p := range []string{"https://", "http://"} {
		s = strings.TrimPrefix(s, p)
	}
	return s
}

func expandUser(p string) string {
	if !strings.HasPrefix(p, "~") {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return p
	}
	return filepath.Join(home, strings.TrimPrefix(p, "~"))
}

// String renders a Map summary for diagnostics output.
func (m *Map) String() string {
	if m == nil {
		return "<no repo map>"
	}
	return fmt.Sprintf("repo-map: %d entries across %d roots, updated %s",
		len(m.Entries), len(m.Roots), m.UpdatedAt.Format(time.RFC3339))
}
