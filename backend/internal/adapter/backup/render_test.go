package backup

import (
	"os/exec"
	"strings"
	"testing"
)

func renderSample(t *testing.T, p BackupProfile) RenderedArtifacts {
	t.Helper()
	if p.WorkDir == "" {
		p.WorkDir = "/var/backups/claude-bar/abc123" // post-save profiles always have one
	}
	art, err := Render(p, "/home/deploy/.claude-bar-backup/abc123")
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	return art
}

func TestRenderCronLine(t *testing.T) {
	p := sampleProfile()
	p.Schedule = Schedule{TimeOfDay: "02:30", Mechanism: "cron"}
	art := renderSample(t, p)
	want := "30 2 * * * /home/deploy/.claude-bar-backup/abc123/backup.sh"
	if !strings.HasPrefix(art.CronLine, want) {
		t.Errorf("cron line = %q, want prefix %q", art.CronLine, want)
	}
	if art.ServiceUnit != "" {
		t.Error("cron mechanism should not emit a systemd unit")
	}
}

func TestRenderSystemdUnits(t *testing.T) {
	p := sampleProfile()
	p.Schedule = Schedule{TimeOfDay: "23:05", Mechanism: "systemd"}
	art := renderSample(t, p)
	if !strings.Contains(art.TimerUnit, "OnCalendar=*-*-* 23:05:00") {
		t.Errorf("timer unit missing OnCalendar: %q", art.TimerUnit)
	}
	if !strings.Contains(art.ServiceUnit, "ExecStart=/home/deploy/.claude-bar-backup/abc123/backup.sh") {
		t.Errorf("service unit ExecStart wrong: %q", art.ServiceUnit)
	}
}

func TestRenderCommandSource(t *testing.T) {
	art := renderSample(t, sampleProfile())
	if !strings.Contains(art.BackupScript, `docker exec pg pg_dump -U app db > "$STAGE/db.dump"`) {
		t.Errorf("backup script missing dump line:\n%s", art.BackupScript)
	}
	if !strings.Contains(art.RestoreScript, `docker exec -i pg psql -U app db < "$TMP/x/db.dump"`) {
		t.Errorf("restore script missing restore line:\n%s", art.RestoreScript)
	}
}

func TestRenderPathAndVolumeSources(t *testing.T) {
	p := sampleProfile()
	p.Sources = []BackupSource{
		{Kind: SourcePath, Name: "config", Paths: []string{"/etc/app", "/srv/data"}},
		{Kind: SourceVolume, Name: "vols", Volumes: []string{"app_pgdata"}},
	}
	art := renderSample(t, p)
	if !strings.Contains(art.BackupScript, `tar -czPf "$STAGE/config.tar.gz" '/etc/app' '/srv/data'`) {
		t.Errorf("path tar line wrong:\n%s", art.BackupScript)
	}
	if !strings.Contains(art.BackupScript, `docker run --rm -v 'app_pgdata':/v:ro -v "$STAGE":/out alpine tar -czf '/out/vols-app_pgdata.tar.gz' -C /v .`) {
		t.Errorf("volume tar line wrong:\n%s", art.BackupScript)
	}
}

func TestRenderRetentionCounts(t *testing.T) {
	p := sampleProfile()
	p.Retention = Retention{Daily: 14, Weekly: 8, Monthly: 6, Yearly: 2}
	art := renderSample(t, p)
	for _, want := range []string{"RETAIN_DAILY=14", "RETAIN_WEEKLY=8", "RETAIN_MONTHLY=6", "RETAIN_YEARLY=2"} {
		if !strings.Contains(art.BackupScript, want) {
			t.Errorf("missing %q in script", want)
		}
	}
}

func TestRenderRejectsInvalid(t *testing.T) {
	p := sampleProfile()
	p.RcloneRemote = "no-colon"
	if _, err := Render(p, "/abs/dir"); err == nil {
		t.Error("expected error for malformed rclone remote")
	}
	if _, err := Render(sampleProfile(), "relative/dir"); err == nil {
		t.Error("expected error for non-absolute installDir")
	}
}

// bash -n is available everywhere we build; the generated scripts must at least
// parse. Catches quoting/heredoc regressions even without shellcheck.
func TestRenderedScriptsParseWithBash(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not installed")
	}
	p := sampleProfile()
	p.Sources = []BackupSource{
		{Kind: SourceCommand, Name: "db", DumpCmd: "docker exec pg pg_dump db", RestoreCmd: "docker exec -i pg psql db"},
		{Kind: SourcePath, Name: "config", Paths: []string{"/etc/app", "/srv/data"}},
		{Kind: SourceVolume, Name: "vols", Volumes: []string{"app_data"}},
	}
	art := renderSample(t, p)
	for name, script := range map[string]string{"backup.sh": art.BackupScript, "restore.sh": art.RestoreScript} {
		cmd := exec.Command("bash", "-n")
		cmd.Stdin = strings.NewReader(script)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Errorf("bash -n %s failed: %v\n%s\n--- script ---\n%s", name, err, out, script)
		}
	}
}

// If shellcheck is on PATH, the generated scripts must pass it. Skips cleanly
// on CI images without shellcheck so the suite stays green either way.
func TestRenderedScriptsPassShellcheck(t *testing.T) {
	if _, err := exec.LookPath("shellcheck"); err != nil {
		t.Skip("shellcheck not installed")
	}
	p := sampleProfile()
	p.Sources = []BackupSource{
		{Kind: SourceCommand, Name: "db", DumpCmd: "docker exec pg pg_dump db", RestoreCmd: "docker exec -i pg psql db"},
		{Kind: SourcePath, Name: "config", Paths: []string{"/etc/app"}},
		{Kind: SourceVolume, Name: "vols", Volumes: []string{"app_data"}},
	}
	art := renderSample(t, p)
	for name, script := range map[string]string{"backup.sh": art.BackupScript, "restore.sh": art.RestoreScript} {
		cmd := exec.Command("shellcheck", "-s", "bash", "-")
		cmd.Stdin = strings.NewReader(script)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Errorf("shellcheck %s failed: %v\n%s", name, err, out)
		}
	}
}
