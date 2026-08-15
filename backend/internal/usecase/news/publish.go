package news

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path"
	"strings"
	"time"

	sshadp "github.com/soi/claude-swap-widget/backend/internal/adapter/ssh"
)

// remoteWriter matches ssh.ExecStdin's signature — a tiny seam so tests can
// inject a fake instead of shelling out to a real ssh binary.
type remoteWriter func(ctx context.Context, host sshadp.TrackedHost, cmd string, stdin []byte, timeout time.Duration) (*sshadp.ExecResult, error)

// hostGetter matches (*ssh.HostStore).Get's signature — the seam Publisher
// and Puller both depend on instead of the concrete store.
type hostGetter interface {
	Get(ctx context.Context, name string) (*sshadp.TrackedHost, error)
}

// Publisher pushes the local news.json snapshot + a manifest (seq/hash) to a
// shared SSH relay host, so Client machines can pull an identical page
// without running local AI aggregation. See pull.go for the reader side.
type Publisher struct {
	Hosts     hostGetter
	ExecStdin remoteWriter
	Now       func() time.Time
	Timeout   time.Duration
	// Dir is the local directory holding the master's news.json snapshot.
	// Defaults to the production news data dir; tests override it.
	Dir string
}

// NewPublisher wires a Publisher against the tracked-host store, the
// production ssh.ExecStdin transport, and the production news data dir.
func NewPublisher(hosts *sshadp.HostStore) *Publisher {
	return &Publisher{
		Hosts:     hosts,
		ExecStdin: sshadp.ExecStdin,
		Now:       func() time.Time { return time.Now().UTC() },
		Timeout:   30 * time.Second,
		Dir:       newsDataDir(),
	}
}

// Publish reads the local news.json off disk, computes its manifest, and
// writes both atomically to <remoteDir> on hostName over SSH: news.json
// FIRST, manifest.json SECOND, so a Client can never observe a manifest
// pointing at a news.json that hasn't landed yet.
func (p *Publisher) Publish(ctx context.Context, hostName, remoteDir string) error {
	if hostName == "" {
		return fmt.Errorf("host is required")
	}
	if remoteDir == "" {
		return fmt.Errorf("remote dir is required")
	}

	dir := p.Dir
	if dir == "" {
		dir = newsDataDir()
	}
	newsBytes, err := os.ReadFile(localFeedPathIn(dir))
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("chưa có news.json để publish")
		}
		return fmt.Errorf("read local news.json: %w", err)
	}

	manifest := computeManifest(newsBytes, p.now())
	manifestBytes, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal manifest: %w", err)
	}

	host, err := p.Hosts.Get(ctx, hostName)
	if err != nil {
		return err
	}

	if err := p.writeRemote(ctx, *host, remoteDir, "news.json", newsBytes); err != nil {
		return fmt.Errorf("publish news.json: %w", err)
	}
	if err := p.writeRemote(ctx, *host, remoteDir, "manifest.json", manifestBytes); err != nil {
		return fmt.Errorf("publish manifest.json: %w", err)
	}
	return nil
}

func (p *Publisher) now() time.Time {
	if p.Now != nil {
		return p.Now()
	}
	return time.Now().UTC()
}

func (p *Publisher) timeout() time.Duration {
	if p.Timeout > 0 {
		return p.Timeout
	}
	return 30 * time.Second
}

// writeRemote atomically writes data to <remoteDir>/<filename> on host:
// mkdir -p the dir, stream data into a .tmp file over stdin, then rename
// into place — a concurrent Client pull never observes a half-written file.
func (p *Publisher) writeRemote(ctx context.Context, host sshadp.TrackedHost, remoteDir, filename string, data []byte) error {
	dest := path.Join(remoteDir, filename)
	tmp := dest + ".tmp"
	cmd := fmt.Sprintf("mkdir -p %s && cat > %s && mv %s %s",
		sshadp.ShellQuote(remoteDir), sshadp.ShellQuote(tmp), sshadp.ShellQuote(tmp), sshadp.ShellQuote(dest))
	execStdin := p.ExecStdin
	if execStdin == nil {
		execStdin = sshadp.ExecStdin
	}
	res, err := execStdin(ctx, host, cmd, data, p.timeout())
	if err != nil {
		return err
	}
	if res.ExitCode != 0 {
		return fmt.Errorf("remote write failed (exit %d): %s", res.ExitCode, strings.TrimSpace(res.Stderr))
	}
	return nil
}
