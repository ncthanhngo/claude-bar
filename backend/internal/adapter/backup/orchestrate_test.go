package backup

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	sshadp "github.com/soi/claude-swap-widget/backend/internal/adapter/ssh"
)

// fakeServer routes exec calls by matching substrings of the command, so tests
// can drive the orchestrator without a real SSH host.
type fakeServer struct {
	home    string
	routes  map[string]string // substring -> stdout
	lastCmd string
}

func (f *fakeServer) exec(_ context.Context, _ sshadp.TrackedHost, cmd string, _ time.Duration) (*sshadp.ExecResult, error) {
	f.lastCmd = cmd
	if strings.Contains(cmd, `"$HOME"`) {
		return &sshadp.ExecResult{Stdout: f.home}, nil
	}
	for sub, out := range f.routes {
		if strings.Contains(cmd, sub) {
			return &sshadp.ExecResult{Stdout: out}, nil
		}
	}
	return &sshadp.ExecResult{Stdout: ""}, nil
}

func newTestOrchestrator(t *testing.T, fs *fakeServer) (*Orchestrator, string) {
	t.Helper()
	dir := t.TempDir()
	hosts := sshadp.NewHostStore(filepath.Join(dir, "hosts.json"))
	if err := hosts.Put(context.Background(), sshadp.TrackedHost{Name: "prod", HostName: "1.2.3.4", User: "deploy"}); err != nil {
		t.Fatalf("seed host: %v", err)
	}
	profiles := NewProfileStore(filepath.Join(dir, "profiles.json"))
	saved, err := profiles.Save(context.Background(), sampleProfile())
	if err != nil {
		t.Fatalf("seed profile: %v", err)
	}
	return &Orchestrator{Profiles: profiles, Hosts: hosts, Exec: fs.exec}, saved.ID
}

func TestResolveHostMissing(t *testing.T) {
	dir := t.TempDir()
	hosts := sshadp.NewHostStore(filepath.Join(dir, "hosts.json")) // empty
	profiles := NewProfileStore(filepath.Join(dir, "profiles.json"))
	saved, _ := profiles.Save(context.Background(), sampleProfile())
	o := &Orchestrator{Profiles: profiles, Hosts: hosts, Exec: (&fakeServer{}).exec}

	_, err := o.Preflight(context.Background(), saved.ID)
	if err == nil || !strings.Contains(err.Error(), "not tracked") {
		t.Fatalf("expected not-tracked error, got %v", err)
	}
}

func TestInstallDirResolution(t *testing.T) {
	fs := &fakeServer{home: "/home/deploy"}
	o, id := newTestOrchestrator(t, fs)
	host, _ := o.Hosts.Get(context.Background(), "prod")
	dir, err := o.installDir(context.Background(), *host, id)
	if err != nil {
		t.Fatalf("installDir: %v", err)
	}
	if dir != "/home/deploy/.claude-bar-backup/"+id {
		t.Errorf("installDir = %q", dir)
	}
}

func TestStatusParsing(t *testing.T) {
	fs := &fakeServer{
		home: "/home/deploy",
		routes: map[string]string{
			"status.json": `{"ts":"2026-06-04T02:30:00+07:00","ok":true,"stamp":"20260604T023000","bytes":1048576,"durationMs":4200}
{"ts":"2026-06-05T02:30:00+07:00","ok":false,"stamp":"20260605T023000","stage":"line:42","error":"see backup.log"}`,
		},
	}
	o, id := newTestOrchestrator(t, fs)
	st, err := o.Status(context.Background(), id)
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if len(st) != 2 {
		t.Fatalf("want 2 status lines, got %d", len(st))
	}
	if !st[0].OK || st[0].Bytes != 1048576 {
		t.Errorf("first status wrong: %+v", st[0])
	}
	if st[1].OK || st[1].Error != "see backup.log" {
		t.Errorf("second status wrong: %+v", st[1])
	}
}

func TestSnapshotsParsing(t *testing.T) {
	fs := &fakeServer{
		home:   "/home/deploy",
		routes: map[string]string{"restore.sh": `{"daily":["prod-20260604T023000.tar.gz"],"weekly":[],"monthly":[],"yearly":[]}`},
	}
	o, id := newTestOrchestrator(t, fs)
	list, err := o.Snapshots(context.Background(), id)
	if err != nil {
		t.Fatalf("snapshots: %v", err)
	}
	if len(list.Daily) != 1 || list.Daily[0] != "prod-20260604T023000.tar.gz" {
		t.Errorf("daily snapshots wrong: %+v", list)
	}
	if list.Weekly == nil || list.Monthly == nil || list.Yearly == nil {
		t.Error("empty tiers must be [] not nil")
	}
}

func TestParseProbeReadiness(t *testing.T) {
	good := strings.Join([]string{
		"CHECK|docker|1|Docker version 24",
		"CHECK|rclone|1|rclone v1.66",
		"CHECK|remote|1|configured",
		"CHECK|remote_reachable|1|ok",
		"CHECK|workdir|1|writable",
		"CHECK|cron|1|available",
		"CHECK|systemd|0|no systemd",
	}, "\n")
	if r := parseProbe(good); !r.Ready {
		t.Errorf("expected ready with cron available: %+v", r)
	}

	bad := strings.Replace(good, "CHECK|rclone|1|rclone v1.66", "CHECK|rclone|0|not found", 1)
	if r := parseProbe(bad); r.Ready {
		t.Error("expected not-ready when rclone missing")
	}

	noSched := strings.Replace(good, "CHECK|cron|1|available", "CHECK|cron|0|missing", 1)
	if r := parseProbe(noSched); r.Ready {
		t.Error("expected not-ready when no scheduler available")
	}
}

func TestBuildInstallScriptCronTagged(t *testing.T) {
	p := sampleProfile()
	p.ID = "abc123"
	p.normalize()
	art, _ := Render(p, "/home/deploy/.claude-bar-backup/abc123")
	script := buildInstallScript(p, art, "/home/deploy/.claude-bar-backup/abc123", "abc123")
	if !strings.Contains(script, "base64 -d >") {
		t.Error("install script should upload via base64")
	}
	if !strings.Contains(script, "claude-bar-backup:abc123") {
		t.Error("cron line should be tagged with the profile id for idempotent replace")
	}
	if !strings.Contains(script, "crontab -") {
		t.Error("install script should write crontab")
	}
}

func TestRemoteName(t *testing.T) {
	if remoteName("sharepoint:Backups/prod") != "sharepoint" {
		t.Error("remoteName split wrong")
	}
	if remoteName("noremote") != "noremote" {
		t.Error("remoteName without colon should return input")
	}
}
