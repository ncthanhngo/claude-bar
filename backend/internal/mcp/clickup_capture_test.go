package mcp

import "testing"

func TestParseCaptureExtractsAllTokens(t *testing.T) {
	cases := []struct {
		in       string
		title    string
		list     string
		priority string
		due      string
		assigns  int
	}{
		{
			in:       "fix login bug !high @vy due fri #Inbox",
			title:    "fix login bug",
			list:     "Inbox",
			priority: "high",
			due:      "fri",
			assigns:  1,
		},
		{
			in:    "Polish release notes",
			title: "Polish release notes",
		},
		{
			in:       "Ship payment !urgent",
			title:    "Ship payment",
			priority: "urgent",
		},
		{
			in:      "Pair with @ann @bob on retro",
			title:   "Pair with on retro",
			assigns: 2,
		},
	}
	for _, c := range cases {
		got := ParseCapture(c.in)
		if got.Text != c.title {
			t.Errorf("%q → title %q, want %q", c.in, got.Text, c.title)
		}
		if got.ListHint != c.list {
			t.Errorf("%q → list %q, want %q", c.in, got.ListHint, c.list)
		}
		if got.Priority != c.priority {
			t.Errorf("%q → priority %q, want %q", c.in, got.Priority, c.priority)
		}
		if got.DueHint != c.due {
			t.Errorf("%q → due %q, want %q", c.in, got.DueHint, c.due)
		}
		if len(got.Assignees) != c.assigns {
			t.Errorf("%q → %d assignees, want %d (%v)", c.in, len(got.Assignees), c.assigns, got.Assignees)
		}
	}
}

func TestParseCaptureKeepsUnknownTokensInTitle(t *testing.T) {
	got := ParseCapture("write blog post about $100/month plan")
	if got.Text != "write blog post about $100/month plan" {
		t.Errorf("unexpected: %q", got.Text)
	}
}
