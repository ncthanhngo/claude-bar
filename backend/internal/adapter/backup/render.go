package backup

import (
	"bytes"
	"embed"
	"fmt"
	"strings"
	"text/template"
)

//go:embed templates/backup.sh.tmpl templates/restore.sh.tmpl
var templatesFS embed.FS

// RenderedArtifacts is everything needed to install a profile on a server.
type RenderedArtifacts struct {
	BackupScript  string `json:"backupScript"`
	RestoreScript string `json:"restoreScript"`
	CronLine      string `json:"cronLine"`
	ServiceUnit   string `json:"serviceUnit"` // systemd .service (empty unless systemd)
	TimerUnit     string `json:"timerUnit"`   // systemd .timer
	InstallDir    string `json:"installDir"`  // absolute, resolved server-side
	Mechanism     string `json:"mechanism"`
}

// scriptData is the template payload for backup.sh / restore.sh.
type scriptData struct {
	WorkDirQ     string
	RemoteQ      string
	InstallDirQ  string
	NameQ        string
	Retention    Retention
	DumpBlock    string
	RestoreBlock string
}

// Render turns a profile into installable artifacts. installDir must be an
// absolute server path (resolved by the orchestrator, e.g. $HOME/.claude-bar-backup/<id>)
// so the cron line and scripts agree on a fixed location.
func Render(p BackupProfile, installDir string) (RenderedArtifacts, error) {
	p.normalize()
	if err := p.Validate(); err != nil {
		return RenderedArtifacts{}, err
	}
	if !strings.HasPrefix(installDir, "/") {
		return RenderedArtifacts{}, fmt.Errorf("installDir must be absolute, got %q", installDir)
	}

	data := scriptData{
		WorkDirQ:     shquote(p.WorkDir),
		RemoteQ:      shquote(p.RcloneRemote),
		InstallDirQ:  shquote(installDir),
		NameQ:        shquote(p.Name),
		Retention:    p.Retention,
		DumpBlock:    buildDumpBlock(p.Sources),
		RestoreBlock: buildRestoreBlock(p.Sources),
	}

	backupScript, err := execTemplate("templates/backup.sh.tmpl", data)
	if err != nil {
		return RenderedArtifacts{}, err
	}
	restoreScript, err := execTemplate("templates/restore.sh.tmpl", data)
	if err != nil {
		return RenderedArtifacts{}, err
	}

	hour, minute, _ := parseHHMM(p.Schedule.TimeOfDay)
	art := RenderedArtifacts{
		BackupScript:  backupScript,
		RestoreScript: restoreScript,
		InstallDir:    installDir,
		Mechanism:     p.Schedule.Mechanism,
		CronLine: fmt.Sprintf("%d %d * * * %s/backup.sh >> %s/backup.log 2>&1",
			minute, hour, installDir, installDir),
	}
	if p.Schedule.Mechanism == "systemd" {
		art.ServiceUnit = fmt.Sprintf(
			"[Unit]\nDescription=Claude Bar backup: %s\n\n[Service]\nType=oneshot\nExecStart=%s/backup.sh\n",
			p.Name, installDir)
		art.TimerUnit = fmt.Sprintf(
			"[Unit]\nDescription=Claude Bar backup timer: %s\n\n[Timer]\nOnCalendar=*-*-* %02d:%02d:00\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n",
			p.Name, hour, minute)
	}
	return art, nil
}

// buildDumpBlock emits the shell that writes each source into $STAGE.
func buildDumpBlock(sources []BackupSource) string {
	var b strings.Builder
	for _, s := range sources {
		fmt.Fprintf(&b, "log %s\n", shquote("dump "+s.Name))
		switch s.Kind {
		case SourceCommand:
			// Operator-authored command runs verbatim; its final stdout (the
			// dump) is redirected. Pipelines are fine — redirect targets the
			// last stage's stdout.
			fmt.Fprintf(&b, "%s > \"$STAGE/%s.dump\"\n", s.DumpCmd, s.Name)
		case SourcePath:
			var paths strings.Builder
			for _, p := range s.Paths {
				paths.WriteString(" " + shquote(p))
			}
			// -P keeps absolute paths so restore lands in the original location.
			fmt.Fprintf(&b, "tar -czPf \"$STAGE/%s.tar.gz\"%s\n", s.Name, paths.String())
		case SourceVolume:
			for _, v := range s.Volumes {
				fmt.Fprintf(&b,
					"docker run --rm -v %s:/v:ro -v \"$STAGE\":/out alpine tar -czf %s -C /v .\n",
					shquote(v), shquote("/out/"+s.Name+"-"+v+".tar.gz"))
			}
		}
	}
	return b.String()
}

// buildRestoreBlock emits the shell that restores each source from $TMP/x.
func buildRestoreBlock(sources []BackupSource) string {
	var b strings.Builder
	for _, s := range sources {
		fmt.Fprintf(&b, "echo %s >&2\n", shquote("restore "+s.Name))
		switch s.Kind {
		case SourceCommand:
			if strings.TrimSpace(s.RestoreCmd) == "" {
				fmt.Fprintf(&b, "echo %s >&2\n", shquote("no restoreCmd for "+s.Name+" — skipped"))
				continue
			}
			// RestoreCmd reads the dump on stdin (e.g. `docker exec -i pg psql …`).
			fmt.Fprintf(&b, "%s < \"$TMP/x/%s.dump\"\n", s.RestoreCmd, s.Name)
		case SourcePath:
			fmt.Fprintf(&b, "tar -xzPf \"$TMP/x/%s.tar.gz\"\n", s.Name)
		case SourceVolume:
			for _, v := range s.Volumes {
				fmt.Fprintf(&b,
					"docker run --rm -v %s:/v -v \"$TMP/x\":/in alpine sh -c %s\n",
					shquote(v),
					shquote(fmt.Sprintf("cd /v && tar -xzf /in/%s-%s.tar.gz", s.Name, v)))
			}
		}
	}
	return b.String()
}

func execTemplate(name string, data scriptData) (string, error) {
	tmpl, err := template.New(name).Delims("{{", "}}").ParseFS(templatesFS, name)
	if err != nil {
		return "", fmt.Errorf("parse %s: %w", name, err)
	}
	// ParseFS names the template by its base filename.
	base := name[strings.LastIndex(name, "/")+1:]
	var buf bytes.Buffer
	if err := tmpl.ExecuteTemplate(&buf, base, data); err != nil {
		return "", fmt.Errorf("execute %s: %w", name, err)
	}
	return buf.String(), nil
}

// shquote wraps a value in single quotes for safe shell interpolation, escaping
// embedded single quotes. Same approach as the ssh adapter's quoting.
func shquote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
