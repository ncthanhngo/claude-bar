package usecase

import (
	"strings"
	"testing"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/cloudsync"
)

func TestCheckAntiRollbackAcceptsHigherSeq(t *testing.T) {
	err := checkAntiRollback(
		&cloudsync.CloudBundle{Seq: 10},
		&cloudsync.SyncState{LastSeq: 5},
	)
	if err != nil {
		t.Fatalf("higher seq should be accepted, got: %v", err)
	}
}

func TestCheckAntiRollbackAcceptsEqualSeq(t *testing.T) {
	err := checkAntiRollback(
		&cloudsync.CloudBundle{Seq: 5},
		&cloudsync.SyncState{LastSeq: 5},
	)
	if err != nil {
		t.Fatalf("equal seq should be accepted, got: %v", err)
	}
}

func TestCheckAntiRollbackRejectsLowerSeq(t *testing.T) {
	err := checkAntiRollback(
		&cloudsync.CloudBundle{Seq: 3},
		&cloudsync.SyncState{LastSeq: 5},
	)
	if err == nil {
		t.Fatal("lower seq must be rejected")
	}
	if !strings.Contains(err.Error(), "rollback") {
		t.Fatalf("error should mention rollback: %v", err)
	}
}

func TestCheckAntiRollbackFreshDeviceAcceptsAnything(t *testing.T) {
	err := checkAntiRollback(
		&cloudsync.CloudBundle{Seq: 100},
		&cloudsync.SyncState{LastSeq: 0},
	)
	if err != nil {
		t.Fatalf("fresh device must accept any seq, got: %v", err)
	}
}

func TestCheckAntiRollbackLegacyBundleAccepted(t *testing.T) {
	// V1/V2 bundles have Seq=0 → must be accepted regardless of local state.
	err := checkAntiRollback(
		&cloudsync.CloudBundle{Seq: 0},
		&cloudsync.SyncState{LastSeq: 99},
	)
	if err != nil {
		t.Fatalf("legacy bundle (seq=0) must be accepted, got: %v", err)
	}
}

func TestAccountKeyIsStableByIdentity(t *testing.T) {
	a := cloudsync.BundleAccount{Number: 1, Email: "x@y.z", OrganizationUUID: "u1"}
	b := cloudsync.BundleAccount{Number: 99, Email: "x@y.z", OrganizationUUID: "u1"}
	if accountKey(a) != accountKey(b) {
		t.Fatal("same email + org should produce same key regardless of number")
	}
	c := cloudsync.BundleAccount{Number: 1, Email: "x@y.z", OrganizationUUID: "u2"}
	if accountKey(a) == accountKey(c) {
		t.Fatal("different org should produce different key")
	}
}
