package adapter

import (
	"os"
	"runtime"
	"time"
)

// ReplaceFile renames tmp over dst. On Windows a virus scanner, the search
// indexer or another process briefly holding either file makes the rename
// fail (access denied / sharing violation), so it retries for ~0.5 s there.
func ReplaceFile(tmp, dst string) error {
	var err error
	for i := 0; i < 10; i++ {
		if err = os.Rename(tmp, dst); err == nil || runtime.GOOS != "windows" {
			return err
		}
		time.Sleep(50 * time.Millisecond)
	}
	return err
}
