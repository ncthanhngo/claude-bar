package main

import (
	"os"
	"strings"
	"testing"
)

func TestReadTokenRequiresStdinSentinel(t *testing.T) {
	if _, err := readToken("xoxp-secret"); err == nil || !strings.Contains(err.Error(), "--token=-") {
		t.Fatalf("expected stdin-only error, got %v", err)
	}
}

func TestReadTokenReadsFromStdinOnly(t *testing.T) {
	old := os.Stdin
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { os.Stdin = old }()
	os.Stdin = r
	if _, err := w.WriteString("  pk_test_token  \n"); err != nil {
		t.Fatal(err)
	}
	_ = w.Close()

	got, err := readToken("-")
	if err != nil {
		t.Fatal(err)
	}
	if got != "pk_test_token" {
		t.Fatalf("unexpected token %q", got)
	}
}
