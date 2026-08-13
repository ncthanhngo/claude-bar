package ssh

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// HostHealth is one server's snapshot from a monitor probe. Numeric fields are
// -1 when unavailable (e.g. a non-Linux server without /proc) so a consumer
// can tell "no reading" from a real zero.
type HostHealth struct {
	Name        string      `json:"name"`
	Reachable   bool        `json:"reachable"`
	DiskUsedPct int         `json:"diskUsedPct"` // the worst mount (headline)
	DiskPath    string      `json:"diskPath"`    // the worst mount's path
	Mounts      []DiskMount `json:"mounts"`      // every watched mount
	// Deeper stats (best-effort, Linux /proc based).
	LoadAvg1   float64 `json:"loadAvg1"`   // 1-min load average, -1 if n/a
	MemUsedPct int     `json:"memUsedPct"` // -1 if n/a
	UptimeSecs int64   `json:"uptimeSecs"` // -1 if n/a
	PortOpen   int     `json:"portOpen"`   // -1 unknown, 0 closed, 1 open
	// Static hardware config (best-effort). CPUCores/MemTotalBytes are -1 when
	// unavailable; CPUModel is "" — these don't change between probes but ride
	// along so the Server tab can show "8 cores · 16 GB · <cpu>".
	CPUModel      string `json:"cpuModel,omitempty"`
	CPUCores      int    `json:"cpuCores"`
	MemTotalBytes int64  `json:"memTotalBytes"`
	// RebootRequired mirrors /var/run/reboot-required (Debian/Ubuntu) — a
	// pending-kernel/library signal. Instant file check, so it rides the probe.
	RebootRequired bool `json:"rebootRequired,omitempty"`
	// Services is the per-host watched systemd unit / docker container roster
	// (empty when none configured). Each carries its current up/down state.
	Services []ServiceStatus `json:"services,omitempty"`
	// HostKeyChanged is true when ssh reported the remote key no longer matches
	// known_hosts — a real security signal, surfaced distinctly from "down".
	HostKeyChanged bool `json:"hostKeyChanged"`

	ExitCode   int       `json:"exitCode"`
	DurationMs int64     `json:"durationMs"`
	Error      string    `json:"error,omitempty"`
	CheckedAt  time.Time `json:"checkedAt"`
}

// DiskMount is one filesystem's usage from the probe.
type DiskMount struct {
	Path    string `json:"path"`
	UsedPct int    `json:"usedPct"`
}

// ServiceStatus is one watched service's up/down state. Name is the token the
// user configured (a systemd unit, or "docker:<container>"); State is the raw
// word from the server ("active", "inactive", "running", "missing", …) so the
// UI can show a reason, while Active is the boolean the dot renders from.
type ServiceStatus struct {
	Name   string `json:"name"`
	State  string `json:"state"`
	Active bool   `json:"active"`
}

const probeSectionMark = "@@CSWSEC@@"

// ProbeHealth runs ONE combined command over SSH and interprets it into a
// reachability + resource snapshot. It never returns an error: a failure is
// encoded as Reachable=false with Error set. Reachability follows Exec's
// exit-code contract (255 connect/auth, 124 timeout → down); once ssh connects,
// the host is reachable even if an individual sub-command exits non-zero.
func ProbeHealth(ctx context.Context, host TrackedHost, diskPath string, timeout time.Duration) HostHealth {
	paths := parseDiskPaths(diskPath)
	if timeout <= 0 {
		timeout = 20 * time.Second
	}
	h := HostHealth{
		Name:          host.Name,
		DiskPath:      strings.Join(paths, ","),
		DiskUsedPct:   -1,
		LoadAvg1:      -1,
		MemUsedPct:    -1,
		UptimeSecs:    -1,
		PortOpen:      -1,
		CPUCores:      -1,
		MemTotalBytes: -1,
		CheckedAt:     time.Now().UTC(),
	}

	services := parseServiceList(host.Services)
	res, err := Exec(ctx, host, probeScript(paths, host.CheckPort, services), timeout)
	if res != nil {
		h.ExitCode = res.ExitCode
		h.DurationMs = res.DurationMs
		if hostKeyChanged(res.Stderr) {
			h.HostKeyChanged = true
		}
	}
	if err != nil {
		h.Error = err.Error()
		return h
	}
	// 255 = ssh couldn't connect/authenticate, 124 = our timeout. Anything else
	// means the remote shell actually ran, so the host is reachable.
	if res.ExitCode == 255 || res.ExitCode == 124 {
		if s := strings.TrimSpace(res.Stderr); s != "" {
			h.Error = s
		} else {
			h.Error = fmt.Sprintf("exit %d", res.ExitCode)
		}
		return h
	}

	h.Reachable = true
	parseProbeSections(&h, res.Stdout, host.CheckPort, services)
	return h
}

// probeScript joins the sub-probes with a marker so one round-trip gathers
// disk, load, memory, uptime, CPU, reboot-required, per-service status, and
// (optionally) a local TCP port check. All bits are best-effort — a missing
// source just leaves the field at its zero/unavailable value.
//
// Section order is FIXED and parsed by index in parseProbeSections:
//
//	0 df · 1 loadavg · 2 free · 3 uptime · 4 cpu · 5 reboot · 6 services · 7 port
func probeScript(paths []string, checkPort int, services []string) string {
	quoted := make([]string, len(paths))
	for i, p := range paths {
		quoted[i] = shellQuote(p)
	}
	mark := "echo '" + probeSectionMark + "'"
	// CPU section: model name (line 1, may be empty on ARM) then logical core
	// count (line 2). Model falls back from /proc/cpuinfo to lscpu; cores from
	// nproc to a /proc/cpuinfo processor count.
	cpuCmd := "{ grep -m1 -i 'model name' /proc/cpuinfo 2>/dev/null || " +
		"LC_ALL=C lscpu 2>/dev/null | grep -m1 'Model name'; } | sed -e 's/^[^:]*: *//'; " +
		"nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null"
	parts := []string{
		// timeout-guarded: df blocks indefinitely on a hung network/FUSE mount,
		// which would stall the whole probe until the SSH deadline. Capping it
		// leaves disk% unavailable but keeps every other section readable.
		"timeout 5 df -P " + strings.Join(quoted, " "),
		mark,
		"cat /proc/loadavg 2>/dev/null",
		mark,
		"free -b 2>/dev/null",
		mark,
		"cat /proc/uptime 2>/dev/null",
		mark,
		cpuCmd,
		mark,
		// reboot-required: instant file check, no package tooling.
		"test -e /var/run/reboot-required && echo REBOOT || echo OK",
		mark,
		servicesScript(services),
		mark,
	}
	if checkPort > 0 {
		parts = append(parts, fmt.Sprintf(
			"timeout 3 bash -c ':</dev/tcp/127.0.0.1/%d' 2>/dev/null && echo PORTOPEN || echo PORTCLOSED",
			checkPort))
	}
	return strings.Join(parts, "; ")
}

// servicesScript emits one "name|state" line per watched service. A plain token
// is a systemd unit (`systemctl is-active`); a "docker:<name>" token checks the
// container's running state. Names are shell-quoted — they come from host
// config, so injection must be impossible.
func servicesScript(services []string) string {
	if len(services) == 0 {
		return "true"
	}
	var cmds []string
	for _, s := range services {
		if name, ok := strings.CutPrefix(s, "docker:"); ok {
			q := shellQuote(name)
			cmds = append(cmds, "printf '%s|' "+shellQuote(s)+
				"; docker inspect -f '{{.State.Status}}' "+q+" 2>/dev/null || echo missing")
		} else {
			q := shellQuote(s)
			cmds = append(cmds, "printf '%s|' "+q+
				"; systemctl is-active "+q+" 2>/dev/null || echo unknown")
		}
	}
	return strings.Join(cmds, "; ")
}

func parseProbeSections(h *HostHealth, stdout string, checkPort int, services []string) {
	secs := strings.Split(stdout, probeSectionMark)
	if len(secs) > 0 {
		mounts := parseDiskMounts(secs[0])
		h.Mounts = mounts
		if worst, ok := worstMount(mounts); ok {
			h.DiskUsedPct = worst.UsedPct
			h.DiskPath = worst.Path
		}
	}
	if len(secs) > 1 {
		if v, ok := parseLoad1(secs[1]); ok {
			h.LoadAvg1 = v
		}
	}
	if len(secs) > 2 {
		if used, total, ok := parseMem(secs[2]); ok {
			h.MemUsedPct = used
			h.MemTotalBytes = total
		}
	}
	if len(secs) > 3 {
		if v, ok := parseUptimeSecs(secs[3]); ok {
			h.UptimeSecs = v
		}
	}
	if len(secs) > 4 {
		if model, cores := parseCPU(secs[4]); model != "" || cores > 0 {
			h.CPUModel = model
			if cores > 0 {
				h.CPUCores = cores
			}
		}
	}
	if len(secs) > 5 && strings.Contains(secs[5], "REBOOT") {
		h.RebootRequired = true
	}
	if len(secs) > 6 && len(services) > 0 {
		h.Services = parseServices(secs[6])
	}
	if checkPort > 0 && len(secs) > 7 {
		switch {
		case strings.Contains(secs[7], "PORTOPEN"):
			h.PortOpen = 1
		case strings.Contains(secs[7], "PORTCLOSED"):
			h.PortOpen = 0
		}
	}
}

// parseServiceList splits the host's configured service string (comma/space/
// newline separated) into tokens.
func parseServiceList(s string) []string {
	fields := strings.FieldsFunc(s, func(r rune) bool {
		return r == ',' || r == ' ' || r == '\t' || r == '\n'
	})
	out := make([]string, 0, len(fields))
	for _, f := range fields {
		if f = strings.TrimSpace(f); f != "" {
			out = append(out, f)
		}
	}
	return out
}

// parseServices reads the "name|state" lines from the services probe section.
// Active is true for a running systemd unit ("active") or docker container
// ("running").
func parseServices(s string) []ServiceStatus {
	var out []ServiceStatus
	for _, line := range strings.Split(strings.TrimSpace(s), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		name, state, ok := strings.Cut(line, "|")
		if !ok {
			continue
		}
		state = strings.TrimSpace(state)
		if state == "" {
			state = "unknown"
		}
		out = append(out, ServiceStatus{
			Name:   name,
			State:  state,
			Active: state == "active" || state == "running",
		})
	}
	return out
}

func parseDiskPaths(diskPath string) []string {
	fields := strings.FieldsFunc(diskPath, func(r rune) bool { return r == ',' || r == ' ' || r == '\t' })
	out := make([]string, 0, len(fields))
	for _, f := range fields {
		if f = strings.TrimSpace(f); f != "" {
			out = append(out, f)
		}
	}
	if len(out) == 0 {
		return []string{"/"}
	}
	return out
}

// parseDiskMounts returns one DiskMount per df data line — the Capacity% token
// and the mount point (last field). Header/garbage lines (no %) are skipped.
func parseDiskMounts(dfOutput string) []DiskMount {
	var out []DiskMount
	for _, line := range strings.Split(strings.TrimSpace(dfOutput), "\n") {
		fields := strings.Fields(line)
		for i, f := range fields {
			if !strings.HasSuffix(f, "%") {
				continue
			}
			n, err := strconv.Atoi(strings.TrimSuffix(f, "%"))
			if err != nil || n < 0 || n > 100 {
				continue
			}
			mount := ""
			if i < len(fields)-1 {
				mount = fields[len(fields)-1]
			}
			out = append(out, DiskMount{Path: mount, UsedPct: n})
		}
	}
	return out
}

// worstMount returns the fullest mount — the one that drives the headline bar.
func worstMount(mounts []DiskMount) (DiskMount, bool) {
	worst := DiskMount{UsedPct: -1}
	found := false
	for _, m := range mounts {
		if m.UsedPct > worst.UsedPct {
			worst = m
			found = true
		}
	}
	return worst, found
}

func parseLoad1(s string) (float64, bool) {
	fields := strings.Fields(s)
	if len(fields) == 0 {
		return 0, false
	}
	v, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

// parseMem reads the "Mem:" line of `free -b` and returns used% plus total
// bytes. total is the raw byte figure so the UI can render "16 GB".
func parseMem(s string) (usedPct int, totalBytes int64, ok bool) {
	for _, line := range strings.Split(s, "\n") {
		if !strings.HasPrefix(strings.TrimSpace(line), "Mem:") {
			continue
		}
		f := strings.Fields(line)
		if len(f) < 3 {
			return 0, 0, false
		}
		total, e1 := strconv.ParseFloat(f[1], 64)
		used, e2 := strconv.ParseFloat(f[2], 64)
		if e1 != nil || e2 != nil || total <= 0 {
			return 0, 0, false
		}
		return int((used / total) * 100.0), int64(total), true
	}
	return 0, 0, false
}

// parseCPU reads the CPU probe section: a model-name line and a core-count
// line, in either order. Missing pieces come back as "" / 0 (order-tolerant so
// an empty model line on ARM doesn't swallow the core count).
func parseCPU(s string) (model string, cores int) {
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if n, err := strconv.Atoi(line); err == nil {
			if n > 0 {
				cores = n
			}
			continue
		}
		if model == "" {
			model = line
		}
	}
	return model, cores
}

func parseUptimeSecs(s string) (int64, bool) {
	fields := strings.Fields(s)
	if len(fields) == 0 {
		return 0, false
	}
	v, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, false
	}
	return int64(v), true
}

func hostKeyChanged(stderr string) bool {
	return strings.Contains(stderr, "IDENTIFICATION HAS CHANGED")
}
