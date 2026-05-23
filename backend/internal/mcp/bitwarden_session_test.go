package mcp

import (
	"testing"
	"time"
)

func TestBitwardenSessionUnlockAndIdleExpiry(t *testing.T) {
	s := NewBitwardenSession(20 * time.Millisecond)
	if s.IsUnlocked() {
		t.Errorf("fresh session should be locked")
	}
	s.Unlock("tok123")
	tok, ok := s.Token()
	if !ok || tok != "tok123" {
		t.Errorf("after Unlock, Token() should return tok123, got %q ok=%v", tok, ok)
	}
	time.Sleep(40 * time.Millisecond)
	if _, ok := s.Token(); ok {
		t.Errorf("session should have expired after idle window")
	}
	if s.IsUnlocked() {
		t.Errorf("IsUnlocked must be false post-expiry")
	}
}

func TestBitwardenSessionTokenResetsIdle(t *testing.T) {
	s := NewBitwardenSession(50 * time.Millisecond)
	s.Unlock("tok")
	for i := 0; i < 5; i++ {
		time.Sleep(20 * time.Millisecond)
		if _, ok := s.Token(); !ok {
			t.Fatalf("Token() should keep session alive on each call")
		}
	}
}

func TestBitwardenSessionLockClears(t *testing.T) {
	s := NewBitwardenSession(time.Minute)
	s.Unlock("x")
	s.Lock()
	if _, ok := s.Token(); ok {
		t.Errorf("after Lock() Token should report locked")
	}
}
