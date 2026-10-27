package oauth

import (
	"crypto/sha256"
	"encoding/base64"
	"net/url"
	"testing"
)

func TestNewLoginAttemptBuildsPKCEURL(t *testing.T) {
	a, err := NewLoginAttempt()
	if err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(a.URL)
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	sum := sha256.Sum256([]byte(a.Verifier))
	if q.Get("code_challenge") != base64.RawURLEncoding.EncodeToString(sum[:]) {
		t.Fatalf("challenge does not match verifier")
	}
	if q.Get("state") != a.State || q.Get("client_id") != clientID || q.Get("redirect_uri") != redirectURI {
		t.Fatalf("query %v", q)
	}
	b, _ := NewLoginAttempt()
	if b.State == a.State || b.Verifier == a.Verifier {
		t.Fatal("attempts must not share state or verifier")
	}
}

func TestSplitPastedCode(t *testing.T) {
	cases := []struct {
		in, want string
		ok       bool
	}{
		{" abc#st ", "abc", true},
		{"abc", "abc", true},
		{"abc#other", "", false},
		{"#st", "", false},
		{"  ", "", false},
	}
	for _, c := range cases {
		got, err := SplitPastedCode(c.in, "st")
		if (err == nil) != c.ok || got != c.want {
			t.Errorf("SplitPastedCode(%q) = %q, %v", c.in, got, err)
		}
	}
}
