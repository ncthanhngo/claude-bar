package usecase

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
	"github.com/soi/claude-swap-widget/backend/internal/port"
)

// cachingBackupStore mimics keychain.BackupCredentialStore: Read serves an
// in-process cache, ReadFresh goes to the shared "Keychain".
type cachingBackupStore struct {
	keychain map[int]domain.CredentialBlob
	cache    map[int]domain.CredentialBlob
	writes   map[int]domain.CredentialBlob
}

func newCachingStore(num int, blob domain.CredentialBlob) *cachingBackupStore {
	return &cachingBackupStore{
		keychain: map[int]domain.CredentialBlob{num: blob},
		cache:    map[int]domain.CredentialBlob{num: blob},
		writes:   map[int]domain.CredentialBlob{},
	}
}

func (s *cachingBackupStore) Read(_ context.Context, num int, _ string) (domain.CredentialBlob, error) {
	if b, ok := s.cache[num]; ok {
		return b, nil
	}
	return s.keychain[num], nil
}

func (s *cachingBackupStore) ReadFresh(_ context.Context, num int, _ string) (domain.CredentialBlob, error) {
	s.cache[num] = s.keychain[num]
	return s.keychain[num], nil
}

func (s *cachingBackupStore) Write(_ context.Context, num int, _ string, b domain.CredentialBlob) error {
	s.keychain[num], s.cache[num], s.writes[num] = b, b, b
	return nil
}

func (s *cachingBackupStore) Delete(context.Context, int, string) error { return nil }

// otherProcessRotates rewrites the shared Keychain when the lock is taken,
// as another csw process finishing its refresh would.
type otherProcessRotates struct {
	store   *cachingBackupStore
	num     int
	rotated domain.CredentialBlob
	held    bool
}

func (l *otherProcessRotates) Acquire(context.Context) error {
	l.store.keychain[l.num] = l.rotated
	l.held = true
	return nil
}
func (l *otherProcessRotates) Release() error { l.held = false; return nil }

func freshPayload(at, rt string) *domain.OAuthPayload {
	return &domain.OAuthPayload{AccessToken: at, RefreshToken: rt, ExpiresAt: time.Now().Add(time.Hour).UnixMilli()}
}

func TestRefreshBackupAdoptsRotationFromOtherProcess(t *testing.T) {
	stale := credentialBlob("a1", "r1", time.Now().Add(-time.Minute))
	rotated := credentialBlob("a2", "r2", time.Now().Add(time.Hour))
	store := newCachingStore(2, stale)
	lock := &otherProcessRotates{store: store, num: 2, rotated: rotated}
	refresher := &listTestTokenRefresher{fresh: freshPayload("a3", "r3")}
	svc := &Service{Backup: store, Refresh: refresher, BackupRefreshLock: func() port.FileLock { return lock }}

	got, payload, err := svc.refreshBackup(context.Background(), 2, "two@example.com", false)
	if err != nil {
		t.Fatalf("refreshBackup: %v", err)
	}
	if refresher.calls != 0 {
		t.Fatalf("refresh calls = %d, want 0 (r1 already spent by the other process)", refresher.calls)
	}
	if got != rotated || payload.AccessToken != "a2" {
		t.Fatalf("got %q, want the other process's rotation", got)
	}
	if lock.held {
		t.Fatal("lock not released")
	}
}

func TestRefreshBackupUsesNewerRefreshTokenWhenRotatedButExpired(t *testing.T) {
	stale := credentialBlob("a1", "r1", time.Now().Add(-time.Hour))
	newer := credentialBlob("a2", "r2", time.Now().Add(-time.Minute))
	store := newCachingStore(2, stale)
	lock := &otherProcessRotates{store: store, num: 2, rotated: newer}
	refresher := &recordingRefresher{fresh: freshPayload("a3", "r3")}
	svc := &Service{Backup: store, Refresh: refresher, BackupRefreshLock: func() port.FileLock { return lock }}

	got, _, err := svc.refreshBackup(context.Background(), 2, "two@example.com", false)
	if err != nil {
		t.Fatalf("refreshBackup: %v", err)
	}
	if refresher.used != "r2" {
		t.Fatalf("refreshed with %q, want r2", refresher.used)
	}
	if store.keychain[2] != got {
		t.Fatal("rotated credential not persisted")
	}
}

func TestRefreshBackupRefusesTokenSharedWithLive(t *testing.T) {
	blob := credentialBlob("a1", "shared", time.Now().Add(-time.Minute))
	refresher := &listTestTokenRefresher{fresh: freshPayload("a2", "r2")}
	svc := &Service{
		Backup:  newCachingStore(2, blob),
		Live:    &listTestLiveStore{blob: credentialBlob("live", "shared", time.Now().Add(time.Hour))},
		Refresh: refresher,
	}

	if _, _, err := svc.refreshBackup(context.Background(), 2, "two@example.com", true); !errors.Is(err, errSharedWithLive) {
		t.Fatalf("err = %v, want errSharedWithLive", err)
	}
	if refresher.calls != 0 {
		t.Fatal("spent the live session's refresh token")
	}
}

func TestRefreshBackupReturnsRefreshError(t *testing.T) {
	store := newCachingStore(2, credentialBlob("a1", "r1", time.Now().Add(-time.Minute)))
	svc := &Service{Backup: store, Refresh: &listTestTokenRefresher{err: errors.New(`oauth refresh 400: {"error":"invalid_grant"}`)}}

	if _, _, err := svc.refreshBackup(context.Background(), 2, "two@example.com", false); !isInvalidGrant(err) {
		t.Fatalf("err = %v, want invalid_grant", err)
	}
	if len(store.writes) != 0 {
		t.Fatal("backup must stay untouched on failure")
	}
}

func TestSwitchTargetReadComesFromKeychainUnderLock(t *testing.T) {
	// Cache holds R1 with runway; another process rotated it to R2 meanwhile.
	cached := credentialBlob("a1", "r1", time.Now().Add(time.Hour))
	rotated := credentialBlob("a2", "r2", time.Now().Add(time.Hour))
	store := newCachingStore(2, cached)
	lock := &otherProcessRotates{store: store, num: 2, rotated: rotated}
	svc := &Service{Backup: store, Refresh: &listTestTokenRefresher{}, BackupRefreshLock: func() port.FileLock { return lock }}

	got, err := svc.credentialFromBackup(context.Background(), &domain.Account{Number: 2, Email: "two@example.com"}, true)
	if err != nil {
		t.Fatal(err)
	}
	if got != rotated {
		t.Fatalf("would install %q into live, want the rotated credential", got)
	}
}

type recordingRefresher struct {
	used  string
	fresh *domain.OAuthPayload
}

func (r *recordingRefresher) Refresh(_ context.Context, refreshToken string) (*domain.OAuthPayload, error) {
	r.used = refreshToken
	return r.fresh, nil
}
