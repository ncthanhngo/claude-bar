package wincreds

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

const loginA = `{"claudeAiOauth":{"accessToken":"a","refreshToken":"ra","expiresAt":1}}`
const loginB = `{"claudeAiOauth":{"accessToken":"b","refreshToken":"rb","expiresAt":2}}`

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestCredmanEnabled(t *testing.T) {
	cfg := filepath.Join(t.TempDir(), ".claude.json")
	noEnv := func(string) string { return "" }

	if credmanEnabled(noEnv, cfg) {
		t.Fatal("no config: want plaintext")
	}
	if !credmanEnabled(func(k string) string {
		if k == "CLAUDE_CODE_FORCE_WINDOWS_CREDMAN" {
			return "1"
		}
		return ""
	}, cfg) {
		t.Fatal("env override ignored")
	}
	writeFile(t, cfg, `{"cachedGrowthBookFeatures":{"tengu_windows_credman":true}}`)
	if !credmanEnabled(noEnv, cfg) {
		t.Fatal("flag ignored")
	}
	writeFile(t, cfg, `{"cachedGrowthBookFeatures":{"tengu_windows_credman":false}}`)
	if credmanEnabled(noEnv, cfg) {
		t.Fatal("flag off ignored")
	}
}

func TestBlobEncodingRoundTrip(t *testing.T) {
	for _, enc := range []blobEncoding{encUTF8, encUTF16LE} {
		got, gotEnc, err := decodeBlob(encodeBlob(loginA, enc))
		if err != nil || got != loginA || gotEnc != enc {
			t.Fatalf("enc %d: got %q %d %v", enc, got, gotEnc, err)
		}
	}
	if _, _, err := decodeBlob([]byte("not json")); err == nil {
		t.Fatal("garbage decoded")
	}
}

func TestPickCredmanPrefersDefaultTarget(t *testing.T) {
	entries := []credEntry{
		{target: "Claude Code-other", blob: []byte(`{"mcpOAuth":{}}`)},
		{target: "Claude Code-alt", blob: []byte(loginB)},
		{target: defaultCredmanTarget, blob: encodeBlob(loginA, encUTF16LE)},
	}
	e, ok := pickCredman(entries)
	if !ok || e.target != defaultCredmanTarget {
		t.Fatalf("picked %q", e.target)
	}
	if _, ok := pickCredman(entries[:1]); ok {
		t.Fatal("picked an entry without claudeAiOauth")
	}
}

type fakeCredman struct {
	entries map[string][]byte
	writes  int
}

func (f *fakeCredman) list(prefix string) ([]credEntry, error) {
	var out []credEntry
	for k, v := range f.entries {
		if strings.HasPrefix(k, prefix) {
			out = append(out, credEntry{target: k, blob: v})
		}
	}
	return out, nil
}

func (f *fakeCredman) write(target string, blob []byte, create bool) error {
	if _, exists := f.entries[target]; !exists && !create {
		return errors.New("not found")
	}
	f.entries[target] = blob
	f.writes++
	return nil
}

func on() bool  { return true }
func off() bool { return false }

func TestLiveStorePlaintextFile(t *testing.T) {
	file := filepath.Join(t.TempDir(), ".claude", ".credentials.json")
	s := newLiveStore(file, off, nil)
	ctx := context.Background()

	if got, err := s.Read(ctx); err != nil || got != "" {
		t.Fatalf("missing file: %q %v", got, err)
	}
	if err := s.Write(ctx, loginA); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.Read(ctx); got != loginA {
		t.Fatalf("read %q", got)
	}
	if err := s.Write(ctx, loginB); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(file); string(b) != loginB {
		t.Fatalf("file %q", b)
	}
}

func TestLiveStoreCredmanKeepsTargetAndEncoding(t *testing.T) {
	cm := &fakeCredman{entries: map[string][]byte{"Claude Code-x": encodeBlob(loginA, encUTF16LE)}}
	s := newLiveStore(filepath.Join(t.TempDir(), ".credentials.json"), on, cm)
	ctx := context.Background()

	if got, _ := s.Read(ctx); got != domain.CredentialBlob(loginA) {
		t.Fatalf("read %q", got)
	}
	if err := s.Write(ctx, loginB); err != nil {
		t.Fatal(err)
	}
	if len(cm.entries) != 1 {
		t.Fatalf("created extra entries: %v", cm.entries)
	}
	if got, enc, _ := decodeBlob(cm.entries["Claude Code-x"]); got != loginB || enc != encUTF16LE {
		t.Fatalf("entry %q enc %d", got, enc)
	}
}

func TestLiveStoreCredmanEnabledButLoginInFile(t *testing.T) {
	file := filepath.Join(t.TempDir(), ".credentials.json")
	writeFile(t, file, loginA)
	cm := &fakeCredman{entries: map[string][]byte{}}
	s := newLiveStore(file, on, cm)

	if err := s.Write(context.Background(), loginB); err != nil {
		t.Fatal(err)
	}
	if cm.writes != 0 {
		t.Fatal("wrote Credential Manager while the login lives in the file")
	}
	if b, _ := os.ReadFile(file); string(b) != loginB {
		t.Fatalf("file %q", b)
	}
}

func TestLiveStoreCredmanCreatesDefaultTargetWhenNothingStored(t *testing.T) {
	cm := &fakeCredman{entries: map[string][]byte{}}
	s := newLiveStore(filepath.Join(t.TempDir(), ".credentials.json"), on, cm)

	if err := s.Write(context.Background(), loginA); err != nil {
		t.Fatal(err)
	}
	if string(cm.entries[defaultCredmanTarget]) != loginA {
		t.Fatalf("entries %v", cm.entries)
	}
}

type droppingCredman struct{ fakeCredman }

func (d *droppingCredman) write(string, []byte, bool) error { return nil }

func TestLiveStoreWriteFailsWhenNotReadBack(t *testing.T) {
	cm := &droppingCredman{fakeCredman{entries: map[string][]byte{defaultCredmanTarget: []byte(loginA)}}}
	s := newLiveStore(filepath.Join(t.TempDir(), ".credentials.json"), on, cm)

	if err := s.Write(context.Background(), loginB); err == nil {
		t.Fatal("silent write loss not reported")
	}
}

func xor(b []byte) ([]byte, error) {
	out := make([]byte, len(b))
	for i, c := range b {
		out[i] = c ^ 0x5a
	}
	return out, nil
}

func TestBackupStore(t *testing.T) {
	dir := t.TempDir()
	s := newBackupStore(dir, xor, xor)
	ctx := context.Background()

	if got, err := s.Read(ctx, 1, "One@Example.com"); err != nil || got != "" {
		t.Fatalf("missing backup: %q %v", got, err)
	}
	if err := s.Write(ctx, 1, "One@Example.com", loginA); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.ReadFresh(ctx, 1, "one@example.com"); got != loginA {
		t.Fatalf("read %q", got)
	}
	files, _ := os.ReadDir(dir)
	if len(files) != 1 || strings.Contains(files[0].Name(), "example") {
		t.Fatalf("files %v", files)
	}
	if raw, _ := os.ReadFile(filepath.Join(dir, files[0].Name())); strings.Contains(string(raw), "refreshToken") {
		t.Fatal("backup stored unencrypted")
	}
	if err := s.Delete(ctx, 1, "one@example.com"); err != nil {
		t.Fatal(err)
	}
	if err := s.Delete(ctx, 1, "one@example.com"); err != nil {
		t.Fatalf("second delete: %v", err)
	}
}

const olderLogin = `{"claudeAiOauth":{"accessToken":"o","refreshToken":"ro","expiresAt":1}}`
const newerLogin = `{"claudeAiOauth":{"accessToken":"n","refreshToken":"rn","expiresAt":9}}`

func TestLiveStorePicksNewerOfCredmanAndFile(t *testing.T) {
	file := filepath.Join(t.TempDir(), ".credentials.json")
	writeFile(t, file, newerLogin)
	cm := &fakeCredman{entries: map[string][]byte{defaultCredmanTarget: []byte(olderLogin)}}
	s := newLiveStore(file, on, cm)

	if got, _ := s.Read(context.Background()); got != newerLogin {
		t.Fatalf("read %q, want the newer file login", got)
	}
	if err := s.Write(context.Background(), loginB); err != nil {
		t.Fatal(err)
	}
	if cm.writes != 0 {
		t.Fatal("wrote the stale Credential Manager entry")
	}
}

func TestLiveStoreRejectsOversizedCredmanBlob(t *testing.T) {
	cm := &fakeCredman{entries: map[string][]byte{defaultCredmanTarget: encodeBlob(loginA, encUTF16LE)}}
	s := newLiveStore(filepath.Join(t.TempDir(), ".credentials.json"), on, cm)
	big := `{"claudeAiOauth":{"accessToken":"` + strings.Repeat("x", 2000) + `","refreshToken":"r","expiresAt":3}}`

	if err := s.Write(context.Background(), domain.CredentialBlob(big)); err == nil || !strings.Contains(err.Error(), "limit") {
		t.Fatalf("err = %v, want size limit error", err)
	}
	if cm.writes != 0 {
		t.Fatal("oversized blob written")
	}
}
