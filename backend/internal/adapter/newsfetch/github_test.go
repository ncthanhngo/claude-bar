package newsfetch

import (
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/port"
)

func TestBuildGitHubQuery(t *testing.T) {
	now := time.Date(2026, 8, 15, 0, 0, 0, 0, time.UTC)
	cases := []struct {
		name string
		q    port.GitHubQuery
		want string
	}{
		{"language only", port.GitHubQuery{Language: "Go"}, "language:Go pushed:>2025-02-15"},
		{"topic only", port.GitHubQuery{Topic: "llm"}, "topic:llm pushed:>2025-02-15"},
		{"both", port.GitHubQuery{Topic: "llm", Language: "Go"}, "topic:llm language:Go pushed:>2025-02-15"},
		{"neither", port.GitHubQuery{}, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := buildGitHubQuery(c.q, now); got != c.want {
				t.Errorf("buildGitHubQuery(%+v, %v) = %q, want %q", c.q, now, got, c.want)
			}
		})
	}
}

func TestLanguageColor(t *testing.T) {
	if got := languageColor("Go"); got != "#00add8" {
		t.Errorf("languageColor(Go) = %q", got)
	}
	if got := languageColor("SomeUnknownLanguage"); got != "#8b949e" {
		t.Errorf("languageColor(unknown) = %q, want the default grey", got)
	}
}
