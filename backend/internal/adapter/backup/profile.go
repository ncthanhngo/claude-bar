// Package backup models server-side backup jobs that the widget configures and
// installs over SSH. A BackupProfile is rendered (render.go) into self-contained
// bash + a cron/systemd schedule, then installed on a tracked SSH host
// (orchestrate.go). The job runs ON THE SERVER and pushes archives to an rclone
// remote (SharePoint) — the Mac is only a control panel. No secrets live here:
// SSH keys are in ~/.ssh, rclone credentials live on the server.
package backup

import (
	"fmt"
	"regexp"
	"strings"
	"time"
)

// SourceKind enumerates what a BackupSource captures.
type SourceKind string

const (
	// SourceCommand runs a freeform dump command on the server (e.g.
	// `docker exec pg pg_dump -U app db`) and captures its stdout to <name>.dump.
	SourceCommand SourceKind = "command"
	// SourcePath tars a set of absolute server paths (bind mounts, config dirs).
	SourcePath SourceKind = "path"
	// SourceVolume tars named docker volumes via a throwaway helper container.
	SourceVolume SourceKind = "volume"
)

// BackupSource is one thing to capture inside a backup archive. The three kinds
// keep the feature DB-agnostic: a Postgres user picks command+pg_dump, a
// volume-only deploy picks volume, a config dir picks path.
type BackupSource struct {
	Kind SourceKind `json:"kind"`
	// Name is the archive member label; must match memberNameRe.
	Name string `json:"name"`

	// command kind:
	DumpCmd    string `json:"dumpCmd,omitempty"`    // stdout captured to <name>.dump
	RestoreCmd string `json:"restoreCmd,omitempty"` // reads <name>.dump on stdin

	// path kind:
	Paths []string `json:"paths,omitempty"` // absolute server paths to tar

	// volume kind:
	Volumes []string `json:"volumes,omitempty"` // docker volume names to tar
}

// Retention is a grandfather-father-son policy: how many archives to keep in
// each tier. The backup script promotes the latest daily into weekly/monthly/
// yearly on calendar boundaries and prunes each tier to its count.
type Retention struct {
	Daily   int `json:"daily"`
	Weekly  int `json:"weekly"`
	Monthly int `json:"monthly"`
	Yearly  int `json:"yearly"`
}

// Schedule controls when the server runs the job.
type Schedule struct {
	TimeOfDay string `json:"timeOfDay"` // "HH:MM" server-local
	Mechanism string `json:"mechanism"` // "cron" | "systemd"
}

// BackupProfile is the full configuration of one backup job.
type BackupProfile struct {
	ID              string         `json:"id"` // uuid, assigned on first save
	Name            string         `json:"name"`
	SSHHost         string         `json:"sshHost"` // matches sshadp.TrackedHost.Name
	Sources         []BackupSource `json:"sources"`
	WorkDir         string         `json:"workDir"`      // server staging dir (absolute)
	RcloneRemote    string         `json:"rcloneRemote"` // "remote:path", e.g. "sharepoint:Backups/prod"
	Retention       Retention      `json:"retention"`
	Schedule        Schedule       `json:"schedule"`
	CreatedAt       time.Time      `json:"createdAt"`
	UpdatedAt       time.Time      `json:"updatedAt"`
	LastInstalledAt *time.Time     `json:"lastInstalledAt,omitempty"`
}

var (
	memberNameRe = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)
	remoteRe     = regexp.MustCompile(`^[A-Za-z0-9_-]+:`)
)

// normalize fills defaults for blank fields and trims whitespace. Applied on
// save so the rest of the pipeline can assume sane values.
func (p *BackupProfile) normalize() {
	p.Name = strings.TrimSpace(p.Name)
	p.SSHHost = strings.TrimSpace(p.SSHHost)
	p.WorkDir = strings.TrimSpace(p.WorkDir)
	p.RcloneRemote = strings.TrimSpace(p.RcloneRemote)

	if p.WorkDir == "" && p.ID != "" {
		p.WorkDir = "/var/backups/claude-bar/" + p.ID
	}
	if p.Retention == (Retention{}) {
		p.Retention = Retention{Daily: 7, Weekly: 4, Monthly: 12, Yearly: 3}
	}
	if p.Schedule.TimeOfDay == "" {
		p.Schedule.TimeOfDay = "02:30"
	}
	if p.Schedule.Mechanism == "" {
		p.Schedule.Mechanism = "cron"
	}
	if p.Sources == nil {
		p.Sources = []BackupSource{}
	}
	for i := range p.Sources {
		if p.Sources[i].Paths == nil {
			p.Sources[i].Paths = []string{}
		}
		if p.Sources[i].Volumes == nil {
			p.Sources[i].Volumes = []string{}
		}
	}
}

// Validate checks the profile is renderable + installable. Run after normalize.
func (p *BackupProfile) Validate() error {
	if p.Name == "" {
		return fmt.Errorf("name is required")
	}
	if p.SSHHost == "" {
		return fmt.Errorf("sshHost is required")
	}
	if len(p.Sources) == 0 {
		return fmt.Errorf("at least one backup source is required")
	}
	if p.WorkDir == "" || !strings.HasPrefix(p.WorkDir, "/") {
		return fmt.Errorf("workDir must be an absolute path")
	}
	if !remoteRe.MatchString(p.RcloneRemote) {
		return fmt.Errorf("rcloneRemote must look like 'remote:path'")
	}
	if p.Schedule.Mechanism != "cron" && p.Schedule.Mechanism != "systemd" {
		return fmt.Errorf("schedule.mechanism must be cron or systemd")
	}
	if _, _, err := parseHHMM(p.Schedule.TimeOfDay); err != nil {
		return err
	}
	for i, s := range p.Sources {
		if !memberNameRe.MatchString(s.Name) {
			return fmt.Errorf("source %d: name %q must match [A-Za-z0-9_-]+", i, s.Name)
		}
		switch s.Kind {
		case SourceCommand:
			if strings.TrimSpace(s.DumpCmd) == "" {
				return fmt.Errorf("source %q: dumpCmd is required for command kind", s.Name)
			}
		case SourcePath:
			if len(s.Paths) == 0 {
				return fmt.Errorf("source %q: at least one path is required", s.Name)
			}
			for _, pth := range s.Paths {
				if !strings.HasPrefix(pth, "/") {
					return fmt.Errorf("source %q: path %q must be absolute", s.Name, pth)
				}
			}
		case SourceVolume:
			if len(s.Volumes) == 0 {
				return fmt.Errorf("source %q: at least one volume is required", s.Name)
			}
		default:
			return fmt.Errorf("source %q: unknown kind %q", s.Name, s.Kind)
		}
	}
	return nil
}

// parseHHMM splits "HH:MM" into hour, minute with range checks. Reused by the
// cron-line renderer.
func parseHHMM(s string) (hour, minute int, err error) {
	parts := strings.SplitN(strings.TrimSpace(s), ":", 2)
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("schedule.timeOfDay must be HH:MM")
	}
	if _, err := fmt.Sscanf(parts[0], "%d", &hour); err != nil {
		return 0, 0, fmt.Errorf("schedule.timeOfDay hour: %w", err)
	}
	if _, err := fmt.Sscanf(parts[1], "%d", &minute); err != nil {
		return 0, 0, fmt.Errorf("schedule.timeOfDay minute: %w", err)
	}
	if hour < 0 || hour > 23 || minute < 0 || minute > 59 {
		return 0, 0, fmt.Errorf("schedule.timeOfDay out of range: %s", s)
	}
	return hour, minute, nil
}
