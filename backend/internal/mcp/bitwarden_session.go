package mcp

import (
	"errors"
	"sync"
	"time"
)

// BitwardenSession holds the in-memory BW_SESSION token + idle timer.
// Token is NEVER persisted to disk by the app — bw itself may write a
// session to its own state, but we re-unlock from scratch each time.
type BitwardenSession struct {
	mu        sync.Mutex
	token     string
	expiresAt time.Time
	idleTTL   time.Duration
}

// NewBitwardenSession returns a session with the given idle TTL (typically
// 15 min). idleTTL ≤ 0 disables auto-lock.
func NewBitwardenSession(idleTTL time.Duration) *BitwardenSession {
	return &BitwardenSession{idleTTL: idleTTL}
}

// Unlock stores the token in memory; resets idle window.
func (s *BitwardenSession) Unlock(token string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.token = token
	s.touchLocked()
}

// Lock zeros the token immediately.
func (s *BitwardenSession) Lock() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.token = ""
	s.expiresAt = time.Time{}
}

// Token returns the active session token + true if the window is still
// valid. After idle, the token is auto-zeroed and (zero, false) is returned.
func (s *BitwardenSession) Token() (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.token == "" {
		return "", false
	}
	if s.idleTTL > 0 && time.Now().After(s.expiresAt) {
		s.token = ""
		s.expiresAt = time.Time{}
		return "", false
	}
	s.touchLocked()
	return s.token, true
}

// IsUnlocked reports state without resetting the idle window. Diagnostics-only.
func (s *BitwardenSession) IsUnlocked() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.token == "" {
		return false
	}
	if s.idleTTL > 0 && time.Now().After(s.expiresAt) {
		return false
	}
	return true
}

// SecondsUntilLock returns the live countdown for UI display. Zero means
// locked already or no idle window configured.
func (s *BitwardenSession) SecondsUntilLock() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.token == "" || s.idleTTL <= 0 {
		return 0
	}
	rem := time.Until(s.expiresAt)
	if rem <= 0 {
		return 0
	}
	return int(rem.Seconds())
}

func (s *BitwardenSession) touchLocked() {
	if s.idleTTL > 0 {
		s.expiresAt = time.Now().Add(s.idleTTL)
	}
}

// ErrBitwardenLocked means the user needs to unlock the vault before this
// tool call can proceed. Surfaced to the LLM verbatim so it tells the user.
var ErrBitwardenLocked = errors.New("bitwarden session is locked — unlock the vault in Claude Bar Diagnostics first")
