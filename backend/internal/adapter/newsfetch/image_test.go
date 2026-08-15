package newsfetch

import "testing"

func TestSanitizeImageURL(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"https ok", "https://example.com/a.jpg", "https://example.com/a.jpg"},
		{"http rejected", "http://example.com/a.jpg", ""},
		{"empty", "", ""},
		{"malformed", "://bad", ""},
		{"relative rejected", "/a.jpg", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := sanitizeImageURL(c.in); got != c.want {
				t.Errorf("sanitizeImageURL(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}
