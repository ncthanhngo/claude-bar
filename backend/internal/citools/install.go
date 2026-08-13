// Package citools installs the machine-wide CI-watch tooling: a `ci-watch`
// CLI (GitLab + GitHub pipeline watcher) into ~/.local/bin and a `glpush`
// zsh function into ~/.zshrc. Applies to every git repo on the machine.
//
// The app's own MCP GitLab connector was removed; ci-watch/glab auth for
// GitLab hosts is no longer auto-bootstrapped from app-managed Keychain
// state. Users who watch GitLab pipelines authenticate `glab` themselves
// (`glab auth login`) — ci-watch.sh still supports that provider.
package citools

import (
	"bytes"
	"context"
	_ "embed"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

//go:embed ci-watch.sh
var ciWatchScript string

//go:embed glpush.zsh
var glpushBlock string

// zshrcMarker is the idempotency sentinel — the first line of glpushBlock.
// Its presence in ~/.zshrc means the block is already installed.
const zshrcMarker = "# ci-watch & các CLI cá nhân"

// Status reports what is installed/configured on this machine.
type Status struct {
	Brew      bool `json:"brew"`
	Glab      bool `json:"glab"`
	Gh        bool `json:"gh"`
	GhAuthed  bool `json:"ghAuthed"`
	CiWatch   bool `json:"ciWatch"`   // ~/.local/bin/ci-watch present & up-to-date
	Glpush    bool `json:"glpush"`    // glpush block present in ~/.zshrc
	Installed bool `json:"installed"` // ci-watch + glpush + gh authed
}

// InstallResult is Status plus a human-readable step log.
type InstallResult struct {
	Status
	Log []string `json:"log"`
}

func home() string { h, _ := os.UserHomeDir(); return h }

func ciWatchPath() string { return filepath.Join(home(), ".local", "bin", "ci-watch") }
func zshrcPath() string   { return filepath.Join(home(), ".zshrc") }

// resolveBin finds an executable on PATH or in the common Homebrew dirs
// (the app's PATH may not include /opt/homebrew/bin when launched from Finder).
func resolveBin(name string) string {
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	for _, d := range []string{"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"} {
		p := filepath.Join(d, name)
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return ""
}

// augEnv ensures child tools (glab/gh and their git/python3 subprocesses)
// can find the Homebrew bin dirs even under a Finder-launched PATH.
func augEnv() []string {
	env := os.Environ()
	path := os.Getenv("PATH")
	for _, d := range []string{"/usr/local/bin", "/opt/homebrew/bin"} {
		if !strings.Contains(":"+path+":", ":"+d+":") {
			path = d + ":" + path
		}
	}
	out := make([]string, 0, len(env)+1)
	replaced := false
	for _, kv := range env {
		if strings.HasPrefix(kv, "PATH=") {
			out = append(out, "PATH="+path)
			replaced = true
			continue
		}
		out = append(out, kv)
	}
	if !replaced {
		out = append(out, "PATH="+path)
	}
	return out
}

func run(ctx context.Context, stdin, name string, args ...string) (string, error) {
	bin := resolveBin(name)
	if bin == "" {
		return "", fmt.Errorf("không tìm thấy %q", name)
	}
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Env = augEnv()
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return strings.TrimSpace(buf.String()), err
}

// Inspect reports what is installed/configured without changing anything.
func Inspect(ctx context.Context) Status {
	var s Status
	s.Brew = resolveBin("brew") != ""
	s.Glab = resolveBin("glab") != ""
	s.Gh = resolveBin("gh") != ""
	if s.Gh {
		if _, err := run(ctx, "", "gh", "auth", "status"); err == nil {
			s.GhAuthed = true
		}
	}
	if b, err := os.ReadFile(ciWatchPath()); err == nil {
		s.CiWatch = bytes.Equal(b, []byte(ciWatchScript))
	}
	if b, err := os.ReadFile(zshrcPath()); err == nil {
		s.Glpush = strings.Contains(string(b), zshrcMarker)
	}
	s.Installed = s.CiWatch && s.Glpush && s.GhAuthed
	return s
}

// Install performs the full setup. Best-effort per step; each step is logged.
func Install(ctx context.Context) InstallResult {
	var log []string
	add := func(f string, a ...any) { log = append(log, fmt.Sprintf(f, a...)) }

	// 1. Ensure glab + gh via Homebrew (user opted into auto-install).
	brew := resolveBin("brew")
	for _, tool := range []string{"glab", "gh"} {
		if resolveBin(tool) != "" {
			continue
		}
		if brew == "" {
			add("⚠️ thiếu %s và không có Homebrew — cài Homebrew rồi `brew install %s`", tool, tool)
			continue
		}
		add("→ brew install %s …", tool)
		if out, err := run(ctx, "", "brew", "install", tool); err != nil {
			add("✗ brew install %s lỗi: %v — %s", tool, err, lastLine(out))
		} else {
			add("✅ đã cài %s", tool)
		}
	}

	// 2. Write ci-watch into ~/.local/bin.
	binDir := filepath.Join(home(), ".local", "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		add("✗ tạo %s lỗi: %v", binDir, err)
	} else if err := os.WriteFile(ciWatchPath(), []byte(ciWatchScript), 0o755); err != nil {
		add("✗ ghi ci-watch lỗi: %v", err)
	} else {
		add("✅ ci-watch → %s", ciWatchPath())
	}

	// 3. Append glpush block to ~/.zshrc (idempotent via marker).
	if err := ensureZshrcBlock(); err != nil {
		add("✗ cập nhật ~/.zshrc lỗi: %v", err)
	} else {
		add("✅ glpush + PATH trong ~/.zshrc")
	}

	// 4. GitLab auth (glab) is no longer app-managed — the app's MCP GitLab
	// connector was removed, so there is no stored PAT to bootstrap from.
	// Users watching GitLab pipelines run `glab auth login` themselves.

	st := Inspect(ctx)
	if st.Installed {
		add("🎉 Hoàn tất — dùng `glpush` thay `git push` ở repo bất kỳ (mở terminal mới).")
	} else {
		add("ℹ️ Cài một phần — xem cảnh báo ở trên.")
	}
	return InstallResult{Status: st, Log: log}
}

// ensureZshrcBlock appends the glpush block to ~/.zshrc once.
func ensureZshrcBlock() error {
	path := zshrcPath()
	if b, err := os.ReadFile(path); err == nil && strings.Contains(string(b), zshrcMarker) {
		return nil // already installed
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	_, err = f.WriteString("\n" + glpushBlock + "\n")
	return err
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return lines[len(lines)-1]
}
