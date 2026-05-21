package cloudsync

import (
	"strings"
	"testing"
)

func TestMCPPayloadRoundTrip(t *testing.T) {
	plaintext := "xoxp-very-secret-token"
	enc, err := EncryptMCPPayload(plaintext, "correct-horse-battery-staple")
	if err != nil {
		t.Fatal(err)
	}
	if enc == "" {
		t.Fatal("ciphertext is empty")
	}
	if strings.Contains(enc, plaintext) {
		t.Fatal("ciphertext leaked plaintext")
	}
	dec, err := DecryptMCPPayload(enc, "correct-horse-battery-staple")
	if err != nil {
		t.Fatal(err)
	}
	if dec != plaintext {
		t.Fatalf("round-trip mismatch: %q != %q", dec, plaintext)
	}
}

func TestMCPPayloadWrongPassphraseFails(t *testing.T) {
	enc, err := EncryptMCPPayload("secret", "right")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecryptMCPPayload(enc, "wrong"); err == nil {
		t.Fatal("expected decrypt to fail with wrong passphrase")
	}
}

func TestMCPPayloadEmptyInputs(t *testing.T) {
	out, err := EncryptMCPPayload("", "x")
	if err != nil || out != "" {
		t.Fatalf("empty plaintext should be empty ciphertext, got %q err=%v", out, err)
	}
	out, err = DecryptMCPPayload("", "x")
	if err != nil || out != "" {
		t.Fatalf("empty ciphertext should be empty plaintext, got %q err=%v", out, err)
	}
}

func TestMCPPayloadDifferentSaltsEachCall(t *testing.T) {
	a, _ := EncryptMCPPayload("same", "p")
	b, _ := EncryptMCPPayload("same", "p")
	if a == b {
		t.Fatal("two encrypts of same plaintext must produce different ciphertexts (random salt)")
	}
}
