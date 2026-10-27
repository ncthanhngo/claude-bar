//go:build windows

package tray

import "testing"

func TestCodeFromCallback(t *testing.T) {
	cases := map[string]string{
		"https://platform.claude.com/oauth/code/callback?code=abc&state=st": "abc#st",
		"https://platform.claude.com/oauth/code/callback?state=st":          "",
		"": "",
	}
	for in, want := range cases {
		if got := codeFromCallback(in); got != want {
			t.Errorf("codeFromCallback(%q) = %q, want %q", in, got, want)
		}
	}
}
