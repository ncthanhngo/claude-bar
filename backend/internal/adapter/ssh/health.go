package ssh

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// HostHealth is one server's reachability + disk snapshot from a monitor
// probe. DiskUsedPct is 0–100 only when Reachable and the df output parsed;
// it is -1 otherwise so a consumer can tell "no data" from "0% used".
type HostHealth struct {
	Name        string    `json:"name"`
	Reachable   bool      `json:"reachable"`
	DiskUsedPct int       `json:"diskUsedPct"`
	DiskPath    string    `json:"diskPath"`
	ExitCode    int       `json:"exitCode"`
	DurationMs  int64     `json:"durationMs"`
	Error       string    `json:"error,omitempty"`
	CheckedAt   time.Time `json:"checkedAt"`
}

// ProbeHealth runs one `df -P <path>` over SSH and interprets the result into
// a reachability + disk snapshot. It never returns an error: a failure is
// encoded as Reachable=false with Error set, because "host down" is a normal
// outcome the monitor renders, not an exceptional one.
//
// Reachability semantics follow Exec's exit-code contract: ssh's own failure
// to connect/auth surfaces as exit 255, a timeout as 124, and a Go error for a
// true launch failure — all treated as unreachable. Only exit 0 with a parsed
// capacity column counts as a healthy disk reading.
func ProbeHealth(ctx context.Context, host TrackedHost, diskPath string, timeout time.Duration) HostHealth {
	if diskPath == "" {
		diskPath = "/"
	}
	if timeout <= 0 {
		timeout = 20 * time.Second
	}
	h := HostHealth{
		Name:        host.Name,
		DiskPath:    diskPath,
		DiskUsedPct: -1,
		CheckedAt:   time.Now().UTC(),
	}

	res, err := Exec(ctx, host, "df -P "+shellQuote(diskPath), timeout)
	if res != nil {
		h.ExitCode = res.ExitCode
		h.DurationMs = res.DurationMs
	}
	if err != nil {
		h.Error = err.Error()
		return h
	}
	if res.ExitCode != 0 {
		if s := strings.TrimSpace(res.Stderr); s != "" {
			h.Error = s
		} else {
			h.Error = fmt.Sprintf("exit %d", res.ExitCode)
		}
		return h
	}

	// df ran (exit 0) → host is reachable even if we fail to parse the number.
	h.Reachable = true
	if pct, ok := parseDiskUsedPct(res.Stdout); ok {
		h.DiskUsedPct = pct
	} else {
		h.Error = "could not parse df output"
	}
	return h
}

// parseDiskUsedPct pulls the Capacity column (e.g. "63%") out of `df -P`
// output. It scans data lines from the bottom and returns the first token
// ending in "%" — robust to the differing header/column widths across Linux
// and macOS df, and to a wrapped Filesystem column.
func parseDiskUsedPct(dfOutput string) (int, bool) {
	lines := strings.Split(strings.TrimSpace(dfOutput), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		for _, f := range strings.Fields(lines[i]) {
			if !strings.HasSuffix(f, "%") {
				continue
			}
			n, err := strconv.Atoi(strings.TrimSuffix(f, "%"))
			if err == nil && n >= 0 && n <= 100 {
				return n, true
			}
		}
	}
	return 0, false
}
