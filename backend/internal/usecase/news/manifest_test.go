package news

import (
	"testing"
	"time"
)

func TestComputeManifest_SeqFromGeneratedAt(t *testing.T) {
	generatedAt := "2026-08-15T08:00:00Z"
	newsBytes := []byte(`{"schemaVersion":1,"generatedAt":"` + generatedAt + `","items":[]}`)
	now := time.Date(2026, 8, 15, 9, 0, 0, 0, time.UTC) // an hour later than GeneratedAt

	m := computeManifest(newsBytes, now)

	wantSeq, _ := time.Parse(time.RFC3339, generatedAt)
	if m.Seq != wantSeq.Unix() {
		t.Errorf("Seq = %d, want %d (derived from GeneratedAt, not wall clock)", m.Seq, wantSeq.Unix())
	}
	if m.GeneratedAt != generatedAt {
		t.Errorf("GeneratedAt = %q, want %q", m.GeneratedAt, generatedAt)
	}
	if m.SchemaVersion != 1 {
		t.Errorf("SchemaVersion = %d, want 1", m.SchemaVersion)
	}
	if len(m.Hash) != 64 { // hex sha256
		t.Errorf("Hash = %q, want 64 hex chars", m.Hash)
	}
}

func TestComputeManifest_FallsBackToNowWhenUnparseable(t *testing.T) {
	now := time.Date(2026, 8, 15, 9, 0, 0, 0, time.UTC)

	cases := []struct {
		name string
		body []byte
	}{
		{"missing generatedAt", []byte(`{"schemaVersion":1,"items":[]}`)},
		{"unparseable generatedAt", []byte(`{"schemaVersion":1,"generatedAt":"not-a-date","items":[]}`)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := computeManifest(c.body, now)
			if c.name == "missing generatedAt" {
				if m.Seq != now.Unix() {
					t.Errorf("Seq = %d, want fallback to now (%d)", m.Seq, now.Unix())
				}
				if m.GeneratedAt != now.UTC().Format(time.RFC3339) {
					t.Errorf("GeneratedAt = %q, want now formatted", m.GeneratedAt)
				}
			} else {
				// Unparseable-but-present GeneratedAt: seq falls back to now,
				// but the original (unparseable) string is preserved verbatim.
				if m.Seq != now.Unix() {
					t.Errorf("Seq = %d, want fallback to now (%d)", m.Seq, now.Unix())
				}
				if m.GeneratedAt != "not-a-date" {
					t.Errorf("GeneratedAt = %q, want original string preserved", m.GeneratedAt)
				}
			}
		})
	}
}

func TestComputeManifest_HashChangesWithBytes(t *testing.T) {
	now := time.Now().UTC()
	a := computeManifest([]byte(`{"generatedAt":"2026-08-15T08:00:00Z","items":[1]}`), now)
	b := computeManifest([]byte(`{"generatedAt":"2026-08-15T08:00:00Z","items":[2]}`), now)
	if a.Hash == b.Hash {
		t.Error("different bytes must hash differently")
	}
}

func TestLocalManifestRoundTrip(t *testing.T) {
	dir := t.TempDir()

	if _, ok, err := readLocalManifest(dir); err != nil || ok {
		t.Fatalf("readLocalManifest on empty dir: ok=%v err=%v, want ok=false err=nil", ok, err)
	}

	want := NewsManifest{SchemaVersion: 1, Seq: 42, Hash: "abc123", GeneratedAt: "2026-08-15T08:00:00Z"}
	if err := writeLocalManifestAtomic(dir, want); err != nil {
		t.Fatalf("writeLocalManifestAtomic: %v", err)
	}

	got, ok, err := readLocalManifest(dir)
	if err != nil || !ok {
		t.Fatalf("readLocalManifest after write: ok=%v err=%v, want ok=true err=nil", ok, err)
	}
	if got != want {
		t.Errorf("readLocalManifest = %+v, want %+v", got, want)
	}
}
