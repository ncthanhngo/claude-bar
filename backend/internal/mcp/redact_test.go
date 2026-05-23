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

func TestRedactGitHubGitLabBitwardenTokens(t *testing.T) {
	cases := []string{
		"ghp_" + strings.Repeat("a", 36),
		"github_pat_" + strings.Repeat("b", 82),
		"gho_" + strings.Repeat("c", 36),
		"ghs_" + strings.Repeat("d", 36),
		"ghu_" + strings.Repeat("e", 36),
		"ghr_" + strings.Repeat("f", 36),
		"glpat-" + strings.Repeat("g", 20),
		"gloas-" + strings.Repeat("h", 20),
		`BW_SESSION="` + strings.Repeat("X", 40) + `"`,
		`{"bw_session":"opaque"}`,
		`{"session":"opaque"}`,
	}
	for _, in := range cases {
		out := Redact(in)
		if !strings.Contains(out, "[REDACTED]") {
			t.Errorf("expected [REDACTED] for %q, got %q", in, out)
		}
	}
}

// Fuzz-style sweep: 1000 token-shaped strings; redactor must catch ≥99 %.
// Generator covers our supported prefixes; assertion is per Red-Team Finding 9.
func TestRedactCatchesFuzzedTokenShapes(t *testing.T) {
	const total = 1000
	prefixes := []struct {
		head string
		tail func(i int) string
	}{
		{"ghp_", func(i int) string { return repeatPattern("aA0bB1", 40+i%10) }},
		{"github_pat_", func(i int) string { return repeatPattern("xY9_", 82+i%6) }},
		{"gho_", func(i int) string { return repeatPattern("zB1cD2", 40+i%5) }},
		{"ghs_", func(i int) string { return repeatPattern("qP7eF3", 40+i%5) }},
		{"glpat-", func(i int) string { return repeatPattern("Mn3-_", 25+i%8) }},
		{"gloas-", func(i int) string { return repeatPattern("Rt5-_", 25+i%8) }},
		{"xoxp-", func(i int) string { return "1-" + repeatPattern("aA0._-", 14+i%5) }},
		{"pk_", func(i int) string { return "1234567_" + repeatPattern("ABCDEF0123456789", 22+i%5) }},
	}
	caught := 0
	for i := 0; i < total; i++ {
		p := prefixes[i%len(prefixes)]
		tok := p.head + p.tail(i)
		out := Redact(tok)
		if strings.Contains(out, "[REDACTED]") {
			caught++
		}
	}
	rate := float64(caught) / float64(total)
	if rate < 0.99 {
		t.Errorf("redactor catch-rate %.2f%% < 99%% (caught %d / %d)", rate*100, caught, total)
	}
}

func repeatPattern(alphabet string, n int) string {
	var b strings.Builder
	for i := 0; i < n; i++ {
		b.WriteByte(alphabet[i%len(alphabet)])
	}
	return b.String()
}
