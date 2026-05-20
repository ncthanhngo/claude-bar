package mcp

import (
	"strings"
	"testing"
)

func TestRedactScrubsTokenShapes(t *testing.T) {
	cases := []string{
		"xoxp-1234567890-aaaaaaaaaaaaa",
		"xoxb-1234567890-aaaaaaaaaaaaa",
		"pk_1234567_ABCDEFGHIJKLMNOPQRSTUV",
		"ya29.aSomeAccessTokenValue-here_ok",
		"1//abcdefghijklmnopqrstuvwxyz01234567890ABCDE",
		`Authorization: Bearer secrettoken123`,
		`{"refresh_token":"oqweir9233-aaa"}`,
	}
	for _, in := range cases {
		out := Redact(in)
		if strings.Contains(out, "[REDACTED]") {
			continue
		}
		t.Errorf("expected [REDACTED] for %q, got %q", in, out)
	}
}

func TestRedactLeavesPlainTextAlone(t *testing.T) {
	in := "hello, world. This is a normal log line with no secrets."
	if got := Redact(in); got != in {
		t.Errorf("unexpected redaction: %q -> %q", in, got)
	}
}
