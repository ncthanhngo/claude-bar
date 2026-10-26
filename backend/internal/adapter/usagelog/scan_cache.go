package usagelog

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// quarterSec is the bucket width of the persisted scan cache. 15 minutes
// divides every real-world UTC offset (+5:30, +5:45, …), so each local
// hour/day/month boundary the report uses falls on a bucket edge in any zone
// and the cache never needs invalidating on a timezone change.
const quarterSec = 15 * 60

// scanCacheVersion guards the on-disk format; a mismatch discards the cache
// and triggers one full rescan.
const scanCacheVersion = 1

// addQuarter folds a whole slot into b. Bucket.Add counts one request per
// call, so the remaining requests of the slot are added on top.
func addQuarter(b *domain.UsageBucket, q usageQuarter) {
	b.Add(q[1], q[2], q[3], q[4])
	b.Requests += int(q[5]) - 1
}

// usageQuarter is the usage total of one 15-minute UTC slot:
// [slot (unix/quarterSec), input, output, cacheCreation, cacheRead, requests].
type usageQuarter [6]int64

// fileState is the incremental scan position of one JSONL log. Claude Code
// only appends to these files, so everything before Offset is already folded
// into Quarters and the next scan resumes from there.
type fileState struct {
	Offset   int64          `json:"offset"` // always just past a '\n'
	Quarters []usageQuarter `json:"quarters"`
}

type scanCache struct {
	Version int                   `json:"version"`
	Files   map[string]*fileState `json:"files"`
}

// loadScanCache returns the persisted cache, or an empty one when the file is
// missing, unreadable or from another format version.
func loadScanCache(path string) *scanCache {
	empty := &scanCache{Version: scanCacheVersion, Files: map[string]*fileState{}}
	if path == "" {
		return empty
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return empty
	}
	var c scanCache
	if json.Unmarshal(b, &c) != nil || c.Version != scanCacheVersion || c.Files == nil {
		return empty
	}
	return &c
}

// saveScanCache writes the cache atomically (temp file + rename) so a
// concurrent csw process never reads a half-written file.
func saveScanCache(path string, c *scanCache) error {
	if path == "" {
		return nil
	}
	b, err := json.Marshal(c)
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".scan-cache-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// foldNewLines reads path from st.Offset to EOF and folds every complete line
// into st. A trailing line without '\n' is a write still in progress — it is
// left unconsumed for the next scan.
func foldNewLines(path string, st *fileState) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	if _, err := f.Seek(st.Offset, io.SeekStart); err != nil {
		return
	}

	slotIdx := make(map[int64]int, len(st.Quarters))
	for i, q := range st.Quarters {
		slotIdx[q[0]] = i
	}
	r := bufio.NewReaderSize(f, 1<<16)
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			return
		}
		st.Offset += int64(len(line))
		addLogLine(line, st, slotIdx)
	}
}

var usageKey = []byte(`"usage"`)

func addLogLine(line []byte, st *fileState, slotIdx map[int64]int) {
	// Most lines are user/tool payloads without a usage block; skipping them
	// before the JSON decode is what keeps a cold scan of large logs cheap.
	if !bytes.Contains(line, usageKey) {
		return
	}
	var entry assistantLogEntry
	if err := json.Unmarshal(line, &entry); err != nil {
		return
	}
	if entry.Type != "assistant" || entry.Message.Usage == nil {
		return
	}
	// Timestamp is RFC3339 UTC in observed logs. Skip lines we cannot
	// place — they would otherwise inflate every bucket.
	ts, err := time.Parse(time.RFC3339, entry.Timestamp)
	if err != nil {
		return
	}
	slot := ts.Unix() / quarterSec
	i, ok := slotIdx[slot]
	if !ok {
		i = len(st.Quarters)
		st.Quarters = append(st.Quarters, usageQuarter{slot})
		slotIdx[slot] = i
	}
	u := entry.Message.Usage
	q := &st.Quarters[i]
	q[1] += u.InputTokens
	q[2] += u.OutputTokens
	q[3] += u.CacheCreation
	q[4] += u.CacheRead
	q[5]++
}
