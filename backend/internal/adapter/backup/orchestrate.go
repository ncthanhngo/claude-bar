package backup

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	sshadp "github.com/soi/claude-swap-widget/backend/internal/adapter/ssh"
)

// SSHRun is the SSH exec dependency, satisfied by sshadp.Exec. Declared as a
// func type so tests can inject a fake server.
type SSHRun func(ctx context.Context, host sshadp.TrackedHost, cmd string, timeout time.Duration) (*sshadp.ExecResult, error)

// Orchestrator drives a backup profile against its SSH host. It owns no state
// beyond its stores + the SSH runner.
type Orchestrator struct {
	Profiles *ProfileStore
	Hosts    *sshadp.HostStore
	Exec     SSHRun
}

// --- result types (JSON shapes shared with the Swift DTOs) ---

type Check struct {
	Name   string `json:"name"`
	OK     bool   `json:"ok"`
	Detail string `json:"detail"`
}

type PreflightResult struct {
	Checks []Check `json:"checks"`
	Ready  bool    `json:"ready"`
}

type BackupStatus struct {
	TS         string `json:"ts"`
	OK         bool   `json:"ok"`
	Stamp      string `json:"stamp,omitempty"`
	Bytes      int64  `json:"bytes,omitempty"`
	DurationMs int64  `json:"durationMs,omitempty"`
	Stage      string `json:"stage,omitempty"`
	Error      string `json:"error,omitempty"`
}

type SnapshotList struct {
	Daily   []string `json:"daily"`
	Weekly  []string `json:"weekly"`
	Monthly []string `json:"monthly"`
	Yearly  []string `json:"yearly"`
}

type RunResult struct {
	Stdout     string        `json:"stdout"`
	Stderr     string        `json:"stderr"`
	ExitCode   int           `json:"exitCode"`
	DurationMs int64         `json:"durationMs"`
	Status     *BackupStatus `json:"status,omitempty"`
}

const longTimeout = 3600 * time.Second

// resolve loads the profile + its tracked SSH host, erroring clearly if the
// host isn't tracked (the user must add it via the SSH card first).
func (o *Orchestrator) resolve(ctx context.Context, id string) (*BackupProfile, sshadp.TrackedHost, error) {
	p, err := o.Profiles.Get(ctx, id)
	if err != nil {
		return nil, sshadp.TrackedHost{}, err
	}
	h, err := o.Hosts.Get(ctx, p.SSHHost)
	if err != nil {
		return nil, sshadp.TrackedHost{}, fmt.Errorf("ssh host %q for profile %q is not tracked — add it in the SSH card first", p.SSHHost, p.Name)
	}
	return p, *h, nil
}

// installDir resolves the absolute install dir on the server: $HOME/.claude-bar-backup/<id>.
func (o *Orchestrator) installDir(ctx context.Context, host sshadp.TrackedHost, id string) (string, error) {
	res, err := o.Exec(ctx, host, `printf %s "$HOME"`, 20*time.Second)
	if err != nil {
		return "", err
	}
	home := strings.TrimSpace(res.Stdout)
	if home == "" || res.ExitCode != 0 {
		return "", fmt.Errorf("could not resolve remote $HOME (exit %d): %s", res.ExitCode, res.Stderr)
	}
	return strings.TrimRight(home, "/") + "/.claude-bar-backup/" + id, nil
}

// Generate renders the artifacts for a profile, resolving the install dir over
// SSH (read-only). Used for the install confirm preview and by `install`.
func (o *Orchestrator) Generate(ctx context.Context, id string) (RenderedArtifacts, error) {
	p, host, err := o.resolve(ctx, id)
	if err != nil {
		return RenderedArtifacts{}, err
	}
	dir, err := o.installDir(ctx, host, id)
	if err != nil {
		return RenderedArtifacts{}, err
	}
	return Render(*p, dir)
}

// Preflight runs a single read-only probe script and parses the checklist.
func (o *Orchestrator) Preflight(ctx context.Context, id string) (PreflightResult, error) {
	p, host, err := o.resolve(ctx, id)
	if err != nil {
		return PreflightResult{}, err
	}
	res, err := o.Exec(ctx, host, buildProbeScript(*p), 60*time.Second)
	if err != nil {
		return PreflightResult{}, err
	}
	return parseProbe(res.Stdout), nil
}

// Install uploads the scripts and registers the schedule. Mutating.
func (o *Orchestrator) Install(ctx context.Context, id string) error {
	p, host, err := o.resolve(ctx, id)
	if err != nil {
		return err
	}
	dir, err := o.installDir(ctx, host, id)
	if err != nil {
		return err
	}
	art, err := Render(*p, dir)
	if err != nil {
		return err
	}
	script := buildInstallScript(*p, art, dir, id)
	res, err := o.Exec(ctx, host, script, 120*time.Second)
	if err != nil {
		return err
	}
	if res.ExitCode != 0 {
		return fmt.Errorf("install failed (exit %d): %s", res.ExitCode, strings.TrimSpace(res.Stderr+res.Stdout))
	}
	return o.Profiles.MarkInstalled(ctx, id, time.Now().UTC())
}

// Uninstall removes the schedule (leaves archives + scripts in place). Mutating.
func (o *Orchestrator) Uninstall(ctx context.Context, id string) error {
	p, host, err := o.resolve(ctx, id)
	if err != nil {
		return err
	}
	dir, err := o.installDir(ctx, host, id)
	if err != nil {
		return err
	}
	var sb strings.Builder
	sb.WriteString("set -e\n")
	sb.WriteString(fmt.Sprintf("crontab -l 2>/dev/null | grep -v %s | crontab - 2>/dev/null || true\n", shquote("claude-bar-backup:"+id)))
	if p.Schedule.Mechanism == "systemd" {
		unit := "claude-bar-backup-" + id
		sb.WriteString(fmt.Sprintf("systemctl --user disable --now %s.timer 2>/dev/null || true\n", unit))
		sb.WriteString(fmt.Sprintf("rm -f %s/../.config/systemd/user/%s.{service,timer} 2>/dev/null || true\n", shquote(dir), unit))
	}
	sb.WriteString("echo UNINSTALLED\n")
	res, err := o.Exec(ctx, host, sb.String(), 60*time.Second)
	if err != nil {
		return err
	}
	if res.ExitCode != 0 {
		return fmt.Errorf("uninstall failed (exit %d): %s", res.ExitCode, res.Stderr)
	}
	return nil
}

// RunNow triggers backup.sh immediately. Mutating.
func (o *Orchestrator) RunNow(ctx context.Context, id string) (RunResult, error) {
	_, host, err := o.resolve(ctx, id)
	if err != nil {
		return RunResult{}, err
	}
	dir, err := o.installDir(ctx, host, id)
	if err != nil {
		return RunResult{}, err
	}
	res, err := o.Exec(ctx, host, shquote(dir+"/backup.sh"), longTimeout)
	if err != nil {
		return RunResult{}, err
	}
	out := toRunResult(res)
	if st, e := o.Status(ctx, id); e == nil && len(st) > 0 {
		out.Status = &st[len(st)-1]
	}
	return out, nil
}

// Status reads the last status lines + a log tail.
func (o *Orchestrator) Status(ctx context.Context, id string) ([]BackupStatus, error) {
	_, host, err := o.resolve(ctx, id)
	if err != nil {
		return nil, err
	}
	dir, err := o.installDir(ctx, host, id)
	if err != nil {
		return nil, err
	}
	res, err := o.Exec(ctx, host, fmt.Sprintf("tail -n 50 %s 2>/dev/null || true", shquote(dir+"/status.json")), 30*time.Second)
	if err != nil {
		return nil, err
	}
	out := []BackupStatus{}
	for _, line := range strings.Split(res.Stdout, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var st BackupStatus
		if json.Unmarshal([]byte(line), &st) == nil {
			out = append(out, st)
		}
	}
	return out, nil
}

// Snapshots lists available restore points per tier via restore.sh --list.
func (o *Orchestrator) Snapshots(ctx context.Context, id string) (SnapshotList, error) {
	_, host, err := o.resolve(ctx, id)
	if err != nil {
		return SnapshotList{}, err
	}
	dir, err := o.installDir(ctx, host, id)
	if err != nil {
		return SnapshotList{}, err
	}
	res, err := o.Exec(ctx, host, shquote(dir+"/restore.sh")+" --list", 60*time.Second)
	if err != nil {
		return SnapshotList{}, err
	}
	list := SnapshotList{Daily: []string{}, Weekly: []string{}, Monthly: []string{}, Yearly: []string{}}
	_ = json.Unmarshal([]byte(strings.TrimSpace(res.Stdout)), &list)
	return list, nil
}

// Restore restores a chosen snapshot (destructive). snapshot is "tier/file".
func (o *Orchestrator) Restore(ctx context.Context, id, snapshot string) (RunResult, error) {
	_, host, err := o.resolve(ctx, id)
	if err != nil {
		return RunResult{}, err
	}
	dir, err := o.installDir(ctx, host, id)
	if err != nil {
		return RunResult{}, err
	}
	cmd := fmt.Sprintf("%s --snapshot %s --yes", shquote(dir+"/restore.sh"), shquote(snapshot))
	res, err := o.Exec(ctx, host, cmd, longTimeout)
	if err != nil {
		return RunResult{}, err
	}
	return toRunResult(res), nil
}

// RcloneListDrives lists SharePoint/OneDrive document libraries reachable with
// the supplied OAuth token JSON, so the user can pick a drive id. The token is
// passed through an env var written by the command (not argv).
func (o *Orchestrator) RcloneListDrives(ctx context.Context, profileID, tokenJSON string) (RunResult, error) {
	_, host, err := o.resolve(ctx, profileID)
	if err != nil {
		return RunResult{}, err
	}
	tok := base64.StdEncoding.EncodeToString([]byte(tokenJSON))
	// Build an ephemeral onedrive remote from the token, then list drives.
	cmd := fmt.Sprintf(
		`TOK="$(printf %%s '%s' | base64 -d)"; rclone backend drives :onedrive: -o token="$TOK" 2>&1`, tok)
	res, err := o.Exec(ctx, host, cmd, 60*time.Second)
	if err != nil {
		return RunResult{}, err
	}
	return toRunResult(res), nil
}

// RcloneCreateRemote writes a named rclone remote on the server pointing at a
// SharePoint document library. Mutating (gated by the UI confirm).
func (o *Orchestrator) RcloneCreateRemote(ctx context.Context, profileID, remoteName, tokenJSON, driveID string) (RunResult, error) {
	_, host, err := o.resolve(ctx, profileID)
	if err != nil {
		return RunResult{}, err
	}
	tok := base64.StdEncoding.EncodeToString([]byte(tokenJSON))
	cmd := fmt.Sprintf(
		`TOK="$(printf %%s '%s' | base64 -d)"; rclone config create %s onedrive token "$TOK" drive_type documentLibrary drive_id %s 2>&1`,
		tok, shquote(remoteName), shquote(driveID))
	res, err := o.Exec(ctx, host, cmd, 60*time.Second)
	if err != nil {
		return RunResult{}, err
	}
	return toRunResult(res), nil
}

// --- helpers ---

func toRunResult(res *sshadp.ExecResult) RunResult {
	return RunResult{Stdout: res.Stdout, Stderr: res.Stderr, ExitCode: res.ExitCode, DurationMs: res.DurationMs}
}

// remoteName returns the part of "remote:path" before the colon.
func remoteName(remote string) string {
	if i := strings.IndexByte(remote, ':'); i >= 0 {
		return remote[:i]
	}
	return remote
}

// buildInstallScript assembles a single idempotent install script: upload both
// scripts via base64, chmod, and register the schedule (cron or systemd user).
func buildInstallScript(p BackupProfile, art RenderedArtifacts, dir, id string) string {
	b64 := func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
	var sb strings.Builder
	sb.WriteString("set -e\n")
	sb.WriteString(fmt.Sprintf("mkdir -p %s %s\n", shquote(dir), shquote(p.WorkDir)))
	sb.WriteString(fmt.Sprintf("printf %%s '%s' | base64 -d > %s\n", b64(art.BackupScript), shquote(dir+"/backup.sh")))
	sb.WriteString(fmt.Sprintf("printf %%s '%s' | base64 -d > %s\n", b64(art.RestoreScript), shquote(dir+"/restore.sh")))
	sb.WriteString(fmt.Sprintf("chmod +x %s %s\n", shquote(dir+"/backup.sh"), shquote(dir+"/restore.sh")))

	if p.Schedule.Mechanism == "systemd" {
		unit := "claude-bar-backup-" + id
		udir := "$HOME/.config/systemd/user"
		sb.WriteString(fmt.Sprintf("mkdir -p %s\n", udir))
		sb.WriteString(fmt.Sprintf("printf %%s '%s' | base64 -d > %s/%s.service\n", b64(art.ServiceUnit), udir, unit))
		sb.WriteString(fmt.Sprintf("printf %%s '%s' | base64 -d > %s/%s.timer\n", b64(art.TimerUnit), udir, unit))
		sb.WriteString("systemctl --user daemon-reload\n")
		sb.WriteString(fmt.Sprintf("systemctl --user enable --now %s.timer\n", unit))
	} else {
		// Replace any prior line tagged with this profile id, then append.
		tag := "claude-bar-backup:" + id
		line := fmt.Sprintf("%s # %s", art.CronLine, tag)
		sb.WriteString(fmt.Sprintf(
			"( crontab -l 2>/dev/null | grep -v %s; printf '%%s\\n' %s ) | crontab -\n",
			shquote(tag), shquote(line)))
	}
	sb.WriteString("echo INSTALLED\n")
	return sb.String()
}

// buildProbeScript renders a read-only checklist probe. Each line is
// CHECK|<name>|<0|1>|<detail>. Parsed by parseProbe.
func buildProbeScript(p BackupProfile) string {
	rn := remoteName(p.RcloneRemote)
	var sb strings.Builder
	sb.WriteString("set +e\n")
	sb.WriteString(`emit() { printf 'CHECK|%s|%s|%s\n' "$1" "$2" "$3"; }` + "\n")
	sb.WriteString(`if command -v docker >/dev/null 2>&1; then emit docker 1 "$(docker --version 2>/dev/null)"; else emit docker 0 "docker not found"; fi` + "\n")
	sb.WriteString(`if command -v rclone >/dev/null 2>&1; then emit rclone 1 "$(rclone version 2>/dev/null | head -1)"; else emit rclone 0 "rclone not found"; fi` + "\n")
	sb.WriteString(fmt.Sprintf(`if rclone listremotes 2>/dev/null | grep -qx %s; then emit remote 1 "configured"; else emit remote 0 %s; fi`+"\n",
		shquote(rn+":"), shquote("remote '"+rn+"' not configured")))
	sb.WriteString(fmt.Sprintf(`if rclone lsd %s >/dev/null 2>&1; then emit remote_reachable 1 ok; else emit remote_reachable 0 "cannot list remote"; fi`+"\n",
		shquote(rn+":")))
	sb.WriteString(fmt.Sprintf(`if mkdir -p %s 2>/dev/null && [ -w %s ]; then emit workdir 1 writable; else emit workdir 0 "not writable"; fi`+"\n",
		shquote(p.WorkDir), shquote(p.WorkDir)))
	sb.WriteString(`if command -v crontab >/dev/null 2>&1; then emit cron 1 available; else emit cron 0 "crontab missing"; fi` + "\n")
	sb.WriteString(`if command -v systemctl >/dev/null 2>&1; then emit systemd 1 available; else emit systemd 0 "no systemd"; fi` + "\n")
	for _, s := range p.Sources {
		if s.Kind == SourceVolume {
			for _, v := range s.Volumes {
				sb.WriteString(fmt.Sprintf(`if docker volume inspect %s >/dev/null 2>&1; then emit %s 1 exists; else emit %s 0 "volume missing"; fi`+"\n",
					shquote(v), shquote("volume_"+v), shquote("volume_"+v)))
			}
		}
	}
	return sb.String()
}

// parseProbe turns CHECK| lines into a PreflightResult and derives readiness.
func parseProbe(stdout string) PreflightResult {
	res := PreflightResult{Checks: []Check{}}
	ok := map[string]bool{}
	for _, line := range strings.Split(stdout, "\n") {
		if !strings.HasPrefix(line, "CHECK|") {
			continue
		}
		parts := strings.SplitN(line, "|", 4)
		if len(parts) != 4 {
			continue
		}
		isOK := parts[2] == "1"
		res.Checks = append(res.Checks, Check{Name: parts[1], OK: isOK, Detail: strings.TrimSpace(parts[3])})
		ok[parts[1]] = isOK
	}
	// Ready when essentials pass and at least one scheduler is available.
	essentials := []string{"docker", "rclone", "remote", "remote_reachable", "workdir"}
	ready := true
	for _, e := range essentials {
		if !ok[e] {
			ready = false
		}
	}
	if !ok["cron"] && !ok["systemd"] {
		ready = false
	}
	// Any failed volume check blocks readiness.
	for name, v := range ok {
		if strings.HasPrefix(name, "volume_") && !v {
			ready = false
		}
	}
	if len(res.Checks) == 0 {
		ready = false
	}
	res.Ready = ready
	return res
}
