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
		Name:        host.Name,
		DiskPath:    strings.Join(paths, ","),
		DiskUsedPct: -1,
		LoadAvg1:    -1,
		MemUsedPct:  -1,
		UptimeSecs:  -1,
		PortOpen:    -1,
		CheckedAt:   time.Now().UTC(),
	}

	res, err := Exec(ctx, host, probeScript(paths, host.CheckPort), timeout)
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
	parseProbeSections(&h, res.Stdout, host.CheckPort)
	return h
}

// probeScript joins the sub-probes with a marker so one round-trip gathers disk,
// load, memory, uptime, and (optionally) a local TCP port check. All resource
// bits are best-effort — a missing /proc just leaves the field at -1.
func probeScript(paths []string, checkPort int) string {
	quoted := make([]string, len(paths))
	for i, p := range paths {
		quoted[i] = shellQuote(p)
	}
	mark := "echo '" + probeSectionMark + "'"
	parts := []string{
		"df -P " + strings.Join(quoted, " "),
		mark,
		"cat /proc/loadavg 2>/dev/null",
		mark,
		"free -b 2>/dev/null",
		mark,
		"cat /proc/uptime 2>/dev/null",
		mark,
	}
	if checkPort > 0 {
		parts = append(parts, fmt.Sprintf(
			"timeout 3 bash -c ':</dev/tcp/127.0.0.1/%d' 2>/dev/null && echo PORTOPEN || echo PORTCLOSED",
			checkPort))
	}
	return strings.Join(parts, "; ")
}

func parseProbeSections(h *HostHealth, stdout string, checkPort int) {
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
		if v, ok := parseMemUsedPct(secs[2]); ok {
			h.MemUsedPct = v
		}
	}
	if len(secs) > 3 {
		if v, ok := parseUptimeSecs(secs[3]); ok {
			h.UptimeSecs = v
		}
	}
	if checkPort > 0 && len(secs) > 4 {
		switch {
		case strings.Contains(secs[4], "PORTOPEN"):
			h.PortOpen = 1
		case strings.Contains(secs[4], "PORTCLOSED"):
			h.PortOpen = 0
		}
	}
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

// parseMemUsedPct reads the "Mem:" line of `free -b` (total, used).
func parseMemUsedPct(s string) (int, bool) {
	for _, line := range strings.Split(s, "\n") {
		if !strings.HasPrefix(strings.TrimSpace(line), "Mem:") {
			continue
		}
		f := strings.Fields(line)
		if len(f) < 3 {
			return 0, false
		}
		total, e1 := strconv.ParseFloat(f[1], 64)
		used, e2 := strconv.ParseFloat(f[2], 64)
		if e1 != nil || e2 != nil || total <= 0 {
			return 0, false
		}
		return int((used / total) * 100.0), true
	}
	return 0, false
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
