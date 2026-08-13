package backup

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func tempStore(t *testing.T) *ProfileStore {
	t.Helper()
	return NewProfileStore(filepath.Join(t.TempDir(), "profiles.json"))
}

func sampleProfile() BackupProfile {
	return BackupProfile{
		Name:         "prod",
		SSHHost:      "prod",
		RcloneRemote: "sharepoint:Backups/prod",
		Sources: []BackupSource{
			{Kind: SourceCommand, Name: "db", DumpCmd: "docker exec pg pg_dump -U app db", RestoreCmd: "docker exec -i pg psql -U app db"},
		},
	}
}

func TestSaveAssignsIDAndDefaults(t *testing.T) {
	s := tempStore(t)
	saved, err := s.Save(context.Background(), sampleProfile())
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	if saved.ID == "" {
		t.Fatal("expected generated id")
	}
	if saved.WorkDir != "/var/backups/claude-bar/"+saved.ID {
		t.Errorf("default workDir wrong: %q", saved.WorkDir)
	}
	if saved.Retention != (Retention{7, 4, 12, 3}) {
		t.Errorf("default retention wrong: %+v", saved.Retention)
	}
	if saved.Schedule.TimeOfDay != "02:30" || saved.Schedule.Mechanism != "cron" {
		t.Errorf("default schedule wrong: %+v", saved.Schedule)
	}
	if saved.CreatedAt.IsZero() || saved.UpdatedAt.IsZero() {
		t.Error("timestamps not set")
	}
}

func TestSaveRejectsInvalid(t *testing.T) {
	s := tempStore(t)
	bad := sampleProfile()
	bad.Sources = nil
	if _, err := s.Save(context.Background(), bad); err == nil {
		t.Fatal("expected validation error for no sources")
	}
}

func TestListGetDeleteRoundtrip(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()
	saved, _ := s.Save(ctx, sampleProfile())

	list, err := s.List(ctx)
	if err != nil || len(list) != 1 {
		t.Fatalf("list: %v len=%d", err, len(list))
	}
	got, err := s.Get(ctx, saved.ID)
	if err != nil || got.Name != "prod" {
		t.Fatalf("get: %v %+v", err, got)
	}
	if err := s.Delete(ctx, saved.ID); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if list, _ := s.List(ctx); len(list) != 0 {
		t.Fatalf("expected empty after delete, got %d", len(list))
	}
}

func TestUpdatePreservesCreatedAt(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()
	saved, _ := s.Save(ctx, sampleProfile())
	created := saved.CreatedAt

	saved.Name = "prod-renamed"
	again, err := s.Save(ctx, *saved)
	if err != nil {
		t.Fatalf("re-save: %v", err)
	}
	if !again.CreatedAt.Equal(created) {
		t.Errorf("createdAt changed on update: %v != %v", again.CreatedAt, created)
	}
	if again.ID != saved.ID {
		t.Errorf("id changed on update")
	}
}

// JSON null arrays break the Swift decoder; the store must persist [] not null.
func TestEmptyListSerializesAsArray(t *testing.T) {
	s := tempStore(t)
	ctx := context.Background()
	saved, _ := s.Save(ctx, sampleProfile())
	_ = s.Delete(ctx, saved.ID)

	list, _ := s.List(ctx)
	b, _ := json.Marshal(list)
	if string(b) != "[]" {
		t.Errorf("empty list should marshal to [], got %s", b)
	}
}

func TestPersistsAcrossInstances(t *testing.T) {
	path := filepath.Join(t.TempDir(), "profiles.json")
	ctx := context.Background()
	s1 := NewProfileStore(path)
	saved, _ := s1.Save(ctx, sampleProfile())

	if _, err := os.Stat(path); err != nil {
		t.Fatalf("file not written: %v", err)
	}
	s2 := NewProfileStore(path)
	got, err := s2.Get(ctx, saved.ID)
	if err != nil {
		t.Fatalf("reload get: %v", err)
	}
	if got.Name != "prod" {
		t.Errorf("reload mismatch: %+v", got)
	}
}
