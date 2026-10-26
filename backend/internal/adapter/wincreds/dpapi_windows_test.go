//go:build windows

package wincreds

import (
	"bytes"
	"testing"
)

func TestDPAPIRoundTrip(t *testing.T) {
	plain := []byte(loginA)
	enc, err := dpapiProtect(plain)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(enc, []byte("refreshToken")) {
		t.Fatal("not encrypted")
	}
	got, err := dpapiUnprotect(enc)
	if err != nil || !bytes.Equal(got, plain) {
		t.Fatalf("round trip: %q %v", got, err)
	}
}
