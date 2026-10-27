//go:build windows

package tray

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/soi/claude-swap-widget/windows/internal/winutil"
)

// tray.log sits next to csw.log. It records what the user clicked and why
// an action did or did not run — never tokens or codes.
var logMu sync.Mutex

func logf(format string, args ...any) {
	logMu.Lock()
	defer logMu.Unlock()
	dir := winutil.LogsDir()
	_ = os.MkdirAll(dir, 0o700)
	path := filepath.Join(dir, "tray.log")
	if st, err := os.Stat(path); err == nil && st.Size() > 1<<20 {
		_ = os.Rename(path, path+".1")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s\n", time.Now().Format("2006-01-02 15:04:05.000"), fmt.Sprintf(format, args...))
}
