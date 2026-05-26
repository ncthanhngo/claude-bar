package mcp

import (
	"testing"
)

func TestGdriveShareValidRoles(t *testing.T) {
	// Whitelist must cover exactly the three Drive roles the tool advertises.
	// "owner" is intentionally absent — ownership transfer has surprising
	// side effects we don't want to expose via this surface.
	want := map[string]bool{"reader": true, "writer": true, "commenter": true}
	if len(gdriveShareValidRoles) != len(want) {
		t.Fatalf("role whitelist size mismatch: got %v, want %v", gdriveShareValidRoles, want)
	}
	for r := range want {
		if !gdriveShareValidRoles[r] {
			t.Errorf("expected role %q to be valid", r)
		}
	}
	if gdriveShareValidRoles["owner"] {
		t.Error("owner role must not be accepted")
	}
}

func TestParseCSVToValuesHappyPath(t *testing.T) {
	csv := "name,score\nAlice,42\nBob,17\n"
	got, err := parseCSVToValues(csv)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("expected 3 rows, got %d", len(got))
	}
	if got[1][0] != "Alice" || got[1][1] != "42" {
		t.Errorf("row 1 mismatch: %v", got[1])
	}
}

func TestParseCSVToValuesEmbeddedCommasAndQuotes(t *testing.T) {
	// RFC 4180 — fields with commas / quotes must round-trip via quoting.
	csv := `name,note
Alice,"hello, world"
Bob,"she said ""hi"""
`
	got, err := parseCSVToValues(csv)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if got[1][1] != "hello, world" {
		t.Errorf("comma-in-field decoded wrong: %v", got[1][1])
	}
	if got[2][1] != `she said "hi"` {
		t.Errorf("escaped-quote decoded wrong: %v", got[2][1])
	}
}

func TestParseCSVToValuesRaggedRowsAllowed(t *testing.T) {
	// Ragged rows (different column counts per line) must NOT fail —
	// the csv.Reader is configured with FieldsPerRecord=-1 specifically
	// to let agents post ad-hoc tables without padding trailing commas.
	csv := "a,b,c\n1,2\n3,4,5,6\n"
	got, err := parseCSVToValues(csv)
	if err != nil {
		t.Fatalf("ragged rows must parse without error, got: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("expected 3 rows, got %d", len(got))
	}
	if len(got[1]) != 2 || len(got[2]) != 4 {
		t.Errorf("ragged row lengths not preserved: row1=%d row2=%d", len(got[1]), len(got[2]))
	}
}

func TestParseCSVToValuesEmpty(t *testing.T) {
	got, err := parseCSVToValues("")
	if err != nil {
		t.Fatalf("empty CSV must parse cleanly, got: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("empty CSV must yield zero rows, got %d", len(got))
	}
}
