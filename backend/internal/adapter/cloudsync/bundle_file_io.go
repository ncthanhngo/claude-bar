// Bundle file IO: atomic write + ring buffer backup rotation.
//
// Atomic write: WriteFile is not atomic — a crash between truncate and full
// write leaves a half-written file that fails AES-GCM tag verification. We
// write to a sibling tmp file then rename — POSIX rename is atomic within the
// same filesystem, so readers never see partial bytes.
//
// Ring buffer: each push rotates the previous bundle into .1, .1 -> .2, etc.
// Keeps BackupCount older versions so a corrupted current bundle (e.g. bird
// daemon evicted mid-write) can be recovered manually or by RecoverLatest.
package cloudsync

import (
	"fmt"
	"os"
	"path/filepath"
)

// BackupCount is the number of rotated copies kept alongside the current
// bundle. Five gives ~5 push-cycles of recovery without bloating iCloud.
const BackupCount = 5

// WriteBundleAtomic writes data to dest atomically: tmp -> fsync -> rename.
func WriteBundleAtomic(dest string, data []byte) error {
	dir := filepath.Dir(dest)
	tmp, err := os.CreateTemp(dir, filepath.Base(dest)+".tmp.*")
	if err != nil {
		return fmt.Errorf("create tmp: %w", err)
	}
	tmpName := tmp.Name()

	cleanup := func() { _ = os.Remove(tmpName) }

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		cleanup()
		return fmt.Errorf("write tmp: %w", err)
	}
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		cleanup()
		return fmt.Errorf("chmod tmp: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		cleanup()
		return fmt.Errorf("fsync tmp: %w", err)
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return fmt.Errorf("close tmp: %w", err)
	}
	if err := os.Rename(tmpName, dest); err != nil {
		cleanup()
		return fmt.Errorf("rename tmp -> dest: %w", err)
	}
	return nil
}

// RotateBackups shifts existing bundle copies down one slot before a new push.
// Layout after rotation (when dest exists):
//
//	dest      -> dest.1
//	dest.1    -> dest.2
//	...
//	dest.{N-1}-> dest.{N}
//	dest.{N}   (dropped)
//
// Missing slots are skipped silently. The current dest is moved last so the
// caller can write a new bundle immediately after.
func RotateBackups(dest string) error {
	// Drop the oldest first so we never overwrite a still-needed slot.
	oldest := backupSlot(dest, BackupCount)
	if err := removeIfExists(oldest); err != nil {
		return fmt.Errorf("drop oldest backup: %w", err)
	}
	for i := BackupCount - 1; i >= 1; i-- {
		from := backupSlot(dest, i)
		to := backupSlot(dest, i+1)
		if err := renameIfExists(from, to); err != nil {
			return fmt.Errorf("rotate %s -> %s: %w", from, to, err)
		}
	}
	// Promote current to .1 so the caller writes a fresh dest.
	if err := renameIfExists(dest, backupSlot(dest, 1)); err != nil {
		return fmt.Errorf("rotate current -> .1: %w", err)
	}
	return nil
}

// BackupPaths returns all existing backup files for dest in newest-first order.
// Used by RecoverLatest and by status reporting.
func BackupPaths(dest string) []string {
	var paths []string
	for i := 1; i <= BackupCount; i++ {
		p := backupSlot(dest, i)
		if _, err := os.Stat(p); err == nil {
			paths = append(paths, p)
		}
	}
	return paths
}

// backupSlot returns the path of the i-th rotated copy (1-indexed).
func backupSlot(dest string, i int) string {
	return fmt.Sprintf("%s.%d", dest, i)
}

func renameIfExists(from, to string) error {
	if _, err := os.Stat(from); os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return err
	}
	return os.Rename(from, to)
}

func removeIfExists(path string) error {
	err := os.Remove(path)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}
