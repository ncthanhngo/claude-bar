// Package wincreds stores Claude credentials on Windows: the live login
// where Claude Code reads it, and per-account backups encrypted with DPAPI.
package wincreds

import (
	"encoding/json"
	"errors"
	"os"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

// defaultCredmanTarget is used only when Claude Code keeps its login in
// Windows Credential Manager but no entry exists yet (macOS uses the same
// name for its Keychain service). Existing entries are discovered instead.
const defaultCredmanTarget = "Claude Code-credentials"

// credmanTargetPrefix filters Credential Manager entries worth inspecting.
const credmanTargetPrefix = "Claude Code"

// credmanEnabled mirrors how Claude Code (2.1.310) picks its backend on
// Windows: CLAUDE_CODE_FORCE_WINDOWS_CREDMAN=1, else the cached GrowthBook
// flag tengu_windows_credman read from the legacy config file, falling back
// to ~/.claude.json. Anything unreadable means the plaintext file.
func credmanEnabled(getenv func(string) string, legacyConfig, claudeJSON string) bool {
	if getenv("CLAUDE_CODE_FORCE_WINDOWS_CREDMAN") == "1" {
		return true
	}
	data, err := os.ReadFile(legacyConfig)
	if err != nil || len(data) == 0 {
		if data, err = os.ReadFile(claudeJSON); err != nil {
			return false
		}
	}
	var cfg struct {
		Features map[string]any `json:"cachedGrowthBookFeatures"`
	}
	if json.Unmarshal(data, &cfg) != nil {
		return false
	}
	on, _ := cfg.Features["tengu_windows_credman"].(bool)
	return on
}

type blobEncoding int

const (
	encUTF8 blobEncoding = iota
	encUTF16LE
)

// decodeBlob returns the credential JSON stored in a Credential Manager
// blob, which tools write either as UTF-8 or as UTF-16LE.
func decodeBlob(b []byte) (string, blobEncoding, error) {
	if utf8.Valid(b) && json.Valid(b) {
		return string(b), encUTF8, nil
	}
	if len(b)%2 == 0 {
		u := make([]uint16, len(b)/2)
		for i := range u {
			u[i] = uint16(b[2*i]) | uint16(b[2*i+1])<<8
		}
		s := strings.TrimPrefix(string(utf16.Decode(u)), "\uFEFF")
		s = strings.TrimRight(s, "\x00")
		if json.Valid([]byte(s)) {
			return s, encUTF16LE, nil
		}
	}
	return "", encUTF8, errors.New("credential blob is not JSON")
}

func encodeBlob(s string, enc blobEncoding) []byte {
	if enc == encUTF8 {
		return []byte(s)
	}
	u := utf16.Encode([]rune(s))
	b := make([]byte, 2*len(u))
	for i, c := range u {
		b[2*i], b[2*i+1] = byte(c), byte(c>>8)
	}
	return b
}

type credEntry struct {
	target string
	blob   []byte
}

// pickCredman returns the entry holding a Claude OAuth login, preferring
// the default target name when several match.
func pickCredman(entries []credEntry) (credEntry, bool) {
	var found []credEntry
	for _, e := range entries {
		s, _, err := decodeBlob(e.blob)
		if err != nil {
			continue
		}
		var probe struct {
			OAuth json.RawMessage `json:"claudeAiOauth"`
		}
		if json.Unmarshal([]byte(s), &probe) == nil && len(probe.OAuth) > 0 {
			found = append(found, e)
		}
	}
	for _, e := range found {
		if e.target == defaultCredmanTarget {
			return e, true
		}
	}
	if len(found) > 0 {
		return found[0], true
	}
	return credEntry{}, false
}
