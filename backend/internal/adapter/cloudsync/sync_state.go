// Per-device sync state for anti-rollback.
//
// Tracks the last seq number this device pushed or accepted, plus the SHA-256
// of the corresponding ciphertext (the "tip" of the hash chain seen by this
// device). On pull, a bundle whose seq is strictly less than lastSeq is a
// rollback attempt and must be rejected. A bundle whose prevHash mismatches
// lastBundleHash means another device wrote between our last sync and this
// pull — accepted but logged.
//
// State is local-only (kept in Application Support) and never synced.
package cloudsync

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
)

// SyncStatePathForTest, when non-empty, overrides the on-disk sync state
// location. Set by tests; never in production.
var SyncStatePathForTest string

// SyncState is the JSON payload persisted at SyncStateFile.
type SyncState struct {
	LastSeq        uint64 `json:"lastSeq"`
	LastBundleHash string `json:"lastBundleHash"`
}

// LoadSyncState reads the state file. Missing file returns a zero state — that
// signals a brand-new device that has never synced.
func LoadSyncState(path string) (*SyncState, error) {
	if SyncStatePathForTest != "" {
		path = SyncStatePathForTest
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return &SyncState{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read sync state: %w", err)
	}
	var s SyncState
	if err := json.Unmarshal(data, &s); err != nil {
		// Treat malformed state as missing — better to re-trust the next pull
		// than to wedge sync permanently.
		return &SyncState{}, nil
	}
	return &s, nil
}

// SaveSyncState writes the state atomically.
func SaveSyncState(path string, s *SyncState) error {
	if SyncStatePathForTest != "" {
		path = SyncStatePathForTest
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal sync state: %w", err)
	}
	return WriteBundleAtomic(path, data)
}

// HashCiphertext returns the hex-encoded SHA-256 of the bundle's encrypted
// bytes. Used as the chain pointer in PrevHash and as the device's tip hash.
func HashCiphertext(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
