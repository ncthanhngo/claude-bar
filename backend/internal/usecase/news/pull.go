package news

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"path"
	"strings"

	sshadp "github.com/soi/claude-swap-widget/backend/internal/adapter/ssh"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// maxRemoteNewsBytes caps how much of the relay's news.json a Client will
// read — news.json is small text+URLs (no image blobs, see contract.md), so
// 2 MiB is generous headroom while still bounding a misbehaving/huge remote.
const maxRemoteNewsBytes = 2 * 1024 * 1024

// maxRemoteManifestBytes caps the manifest read — it's a handful of scalar
// fields, 64 KiB is already generous.
const maxRemoteManifestBytes = 64 * 1024

// remoteReader matches ssh.ReadFile's signature — the seam Puller depends on
// instead of the concrete adapter, so tests can inject canned bytes instead
// of shelling out to a real ssh binary.
type remoteReader func(ctx context.Context, host sshadp.TrackedHost, path string, maxBytes int) (*sshadp.ExecResult, error)

// Puller pulls a Master's published news.json (+manifest) from the shared
// SSH relay host, verifies its integrity hash, rejects rollback attempts,
// and caches the verified snapshot locally so `csw news show` serves it on
// a Client machine with no local AI/fetch.
type Puller struct {
	Hosts    hostGetter
	ReadFile remoteReader
	Store    port.NewsStore
	// Dir is the local directory the last-good manifest cache is read from
	// / written to for the anti-rollback check. Defaults to the production
	// news data dir; tests override it.
	Dir string
}

// NewPuller wires a Puller against the tracked-host store, the production
// ssh.ReadFile transport, the given news snapshot store (so a successful
// pull becomes the new `news show`), and the production news data dir.
func NewPuller(hosts *sshadp.HostStore, store port.NewsStore) *Puller {
	return &Puller{
		Hosts:    hosts,
		ReadFile: sshadp.ReadFile,
		Store:    store,
		Dir:      newsDataDir(),
	}
}

// Pull fetches manifest.json then news.json from <remoteDir> on hostName,
// verifies sha256(news.json) == manifest.Hash, rejects the pull if the
// remote's seq has gone backwards relative to the last cached pull, then
// persists both locally and returns the decoded NewsFeed (role stamped
// "client"). On any verification failure the local cache is left untouched.
func (p *Puller) Pull(ctx context.Context, hostName, remoteDir string) (port.NewsFeed, error) {
	if hostName == "" {
		return port.NewsFeed{}, fmt.Errorf("host is required")
	}
	if remoteDir == "" {
		return port.NewsFeed{}, fmt.Errorf("remote dir is required")
	}

	dir := p.Dir
	if dir == "" {
		dir = newsDataDir()
	}
	readFile := p.ReadFile
	if readFile == nil {
		readFile = sshadp.ReadFile
	}

	host, err := p.Hosts.Get(ctx, hostName)
	if err != nil {
		return port.NewsFeed{}, err
	}

	manifestRes, err := readFile(ctx, *host, path.Join(remoteDir, "manifest.json"), maxRemoteManifestBytes)
	if err != nil {
		return port.NewsFeed{}, fmt.Errorf("read remote manifest: %w", err)
	}
	if manifestRes.ExitCode != 0 {
		return port.NewsFeed{}, fmt.Errorf("read remote manifest (exit %d): %s", manifestRes.ExitCode, strings.TrimSpace(manifestRes.Stderr))
	}
	var manifest NewsManifest
	if err := json.Unmarshal([]byte(manifestRes.Stdout), &manifest); err != nil {
		return port.NewsFeed{}, fmt.Errorf("parse remote manifest: %w", err)
	}

	newsRes, err := readFile(ctx, *host, path.Join(remoteDir, "news.json"), maxRemoteNewsBytes)
	if err != nil {
		return port.NewsFeed{}, fmt.Errorf("read remote news.json: %w", err)
	}
	if newsRes.ExitCode != 0 {
		return port.NewsFeed{}, fmt.Errorf("read remote news.json (exit %d): %s", newsRes.ExitCode, strings.TrimSpace(newsRes.Stderr))
	}
	newsBytes := []byte(newsRes.Stdout)

	if err := verifyHash(newsBytes, manifest.Hash); err != nil {
		return port.NewsFeed{}, err
	}

	localManifest, hadLocal, err := readLocalManifest(dir)
	if err != nil {
		return port.NewsFeed{}, fmt.Errorf("read local manifest cache: %w", err)
	}
	if hadLocal && manifest.Seq < localManifest.Seq {
		return port.NewsFeed{}, fmt.Errorf("rollback rejected: remote seq %d < last seen %d — keeping cached snapshot", manifest.Seq, localManifest.Seq)
	}

	var feed port.NewsFeed
	if err := json.Unmarshal(newsBytes, &feed); err != nil {
		return port.NewsFeed{}, fmt.Errorf("parse remote news.json: %w", err)
	}
	feed.Role = "client"

	if err := p.Store.SaveFeed(ctx, &feed); err != nil {
		return port.NewsFeed{}, fmt.Errorf("cache snapshot: %w", err)
	}
	if err := writeLocalManifestAtomic(dir, manifest); err != nil {
		return port.NewsFeed{}, fmt.Errorf("cache manifest: %w", err)
	}

	return feed, nil
}

// verifyHash rejects newsBytes whose sha256 doesn't match the manifest's
// claimed hash — protects against a torn/partial remote read or a tampered
// relay file being trusted as a real snapshot.
func verifyHash(newsBytes []byte, wantHash string) error {
	sum := sha256.Sum256(newsBytes)
	got := hex.EncodeToString(sum[:])
	if got != wantHash {
		return fmt.Errorf("news.json hash mismatch: manifest says %s, got %s — refusing to trust remote copy", wantHash, got)
	}
	return nil
}
