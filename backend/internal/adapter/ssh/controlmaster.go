package ssh

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

// ControlMaster manages per-host SSH ControlMaster sockets so repeated tool
// calls reuse a single authenticated connection. Lives in
// ~/Library/Application Support/claude-swap-widget/ssh/cm-{hostHash}.sock
// with 0700 parent dir.
type ControlMaster struct {
	dir string

	mu      sync.Mutex
	active  map[string]string // hostName → socket path
}

// NewControlMaster builds a manager rooted at the given socket dir. The
// directory is created on first use with 0700 perms.
func NewControlMaster(socketDir string) *ControlMaster {
	return &ControlMaster{dir: socketDir, active: map[string]string{}}
}

// SocketPath returns the canonical UDS path for a host. Hash keeps the path
// short enough for macOS's 104-char sun_path limit even on long widget-data
// paths under /Users/<longname>/Library/Application Support/....
func (m *ControlMaster) SocketPath(hostName string) string {
	sum := sha256.Sum256([]byte(hostName))
	return filepath.Join(m.dir, "cm-"+hex.EncodeToString(sum[:6])+".sock")
}

// Open starts a ControlMaster for host if one isn't already alive. Liveness
// is probed via `ssh -O check`. Idempotent.
func (m *ControlMaster) Open(ctx context.Context, host TrackedHost) (string, error) {
	if err := os.MkdirAll(m.dir, 0o700); err != nil {
		return "", fmt.Errorf("control master mkdir: %w", err)
	}
	sock := m.SocketPath(host.Name)

	m.mu.Lock()
	defer m.mu.Unlock()

	if m.isAliveLocked(ctx, sock, host) {
		m.active[host.Name] = sock
		return sock, nil
	}
	// Stale socket file from a previous run; remove before re-binding.
	_ = os.Remove(sock)

	args := []string{"-fN", "-M", "-S", sock}
	args = append(args, sshArgs(host)...)
	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(cctx, "ssh", args...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("control master start: %w (%s)", err, out)
	}
	m.active[host.Name] = sock
	return sock, nil
}

// Close runs `ssh -O exit` on the socket; safe to call even if the master
// already died.
func (m *ControlMaster) Close(ctx context.Context, host TrackedHost) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	sock, ok := m.active[host.Name]
	if !ok {
		sock = m.SocketPath(host.Name)
	}
	args := []string{"-S", sock, "-O", "exit"}
	args = append(args, sshArgs(host)...)
	_ = exec.CommandContext(ctx, "ssh", args...).Run()
	delete(m.active, host.Name)
	_ = os.Remove(sock)
	return nil
}

// Check returns true if the master is alive for host.
func (m *ControlMaster) Check(ctx context.Context, host TrackedHost) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	sock := m.SocketPath(host.Name)
	return m.isAliveLocked(ctx, sock, host)
}

func (m *ControlMaster) isAliveLocked(ctx context.Context, sock string, host TrackedHost) bool {
	if _, err := os.Stat(sock); err != nil {
		return false
	}
	args := []string{"-S", sock, "-O", "check"}
	args = append(args, sshArgs(host)...)
	cctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	err := exec.CommandContext(cctx, "ssh", args...).Run()
	return err == nil
}

// Sweep removes every `cm-*.sock` whose master is no longer alive. Called
// on csw boot so a hard kill last session doesn't leave orphan files. The
// liveness check is best-effort: stat-only when ssh CLI is unavailable.
func (m *ControlMaster) Sweep(ctx context.Context) (removed int, err error) {
	entries, err := os.ReadDir(m.dir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return 0, nil
		}
		return 0, err
	}
	for _, e := range entries {
		name := e.Name()
		if !filepath.HasPrefix(name, "cm-") || filepath.Ext(name) != ".sock" {
			continue
		}
		sock := filepath.Join(m.dir, name)
		// Without the host record we can't probe — drop sockets older than
		// 24h on the assumption they're orphans from a prior session.
		info, err := os.Stat(sock)
		if err != nil {
			continue
		}
		if time.Since(info.ModTime()) > 24*time.Hour {
			_ = os.Remove(sock)
			removed++
		}
	}
	return removed, nil
}
