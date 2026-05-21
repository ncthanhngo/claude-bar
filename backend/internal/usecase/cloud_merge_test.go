package usecase

import (
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/cloudsync"
)

func TestMergeRemoteIntoBundlePreservesRemoteOnlyAccount(t *testing.T) {
	now := time.Now().UTC()
	local := &cloudsync.CloudBundle{
		Version: 3,
		Accounts: []cloudsync.BundleAccount{
			{Number: 1, Email: "a@x", OrganizationUUID: "o-a", UpdatedAtTime: now},
		},
	}
	remoteBundle := &cloudsync.CloudBundle{
		Version: 3,
		Accounts: []cloudsync.BundleAccount{
			{Number: 1, Email: "a@x", OrganizationUUID: "o-a", UpdatedAtTime: now.Add(-time.Hour)},
			{Number: 2, Email: "b@x", OrganizationUUID: "o-b", UpdatedAtTime: now.Add(-time.Minute)},
		},
	}
	remoteCT, err := cloudsync.Encrypt(remoteBundle, "p")
	if err != nil {
		t.Fatal(err)
	}

	mergeRemoteIntoBundle(local, remoteCT, "p")

	if len(local.Accounts) != 2 {
		t.Fatalf("expected 2 accounts after merge, got %d", len(local.Accounts))
	}
	found := map[string]bool{}
	for _, a := range local.Accounts {
		found[a.Email] = true
	}
	if !found["a@x"] || !found["b@x"] {
		t.Fatalf("merge dropped an account: %+v", local.Accounts)
	}
}

func TestMergeRemoteIntoBundleRemoteWinsIfNewer(t *testing.T) {
	now := time.Now().UTC()
	local := &cloudsync.CloudBundle{
		Accounts: []cloudsync.BundleAccount{
			{Number: 1, Email: "a@x", OrganizationUUID: "o-a", Nickname: "local-nick", UpdatedAtTime: now.Add(-time.Hour)},
		},
	}
	remoteBundle := &cloudsync.CloudBundle{
		Accounts: []cloudsync.BundleAccount{
			{Number: 1, Email: "a@x", OrganizationUUID: "o-a", Nickname: "remote-nick", UpdatedAtTime: now},
		},
	}
	remoteCT, _ := cloudsync.Encrypt(remoteBundle, "p")

	mergeRemoteIntoBundle(local, remoteCT, "p")

	if local.Accounts[0].Nickname != "remote-nick" {
		t.Fatalf("newer remote nickname should win, got %q", local.Accounts[0].Nickname)
	}
}

func TestMergeRemoteIntoBundleLocalWinsOnTieOrNewer(t *testing.T) {
	now := time.Now().UTC()
	local := &cloudsync.CloudBundle{
		Accounts: []cloudsync.BundleAccount{
			{Number: 1, Email: "a@x", OrganizationUUID: "o-a", Nickname: "local-nick", UpdatedAtTime: now},
		},
	}
	remoteBundle := &cloudsync.CloudBundle{
		Accounts: []cloudsync.BundleAccount{
			{Number: 1, Email: "a@x", OrganizationUUID: "o-a", Nickname: "remote-nick", UpdatedAtTime: now},
		},
	}
	remoteCT, _ := cloudsync.Encrypt(remoteBundle, "p")

	mergeRemoteIntoBundle(local, remoteCT, "p")

	if local.Accounts[0].Nickname != "local-nick" {
		t.Fatalf("local should win on tie, got %q", local.Accounts[0].Nickname)
	}
}

func TestMergeRemoteIntoBundleNoopWhenRemoteMissing(t *testing.T) {
	local := &cloudsync.CloudBundle{
		Accounts: []cloudsync.BundleAccount{{Number: 1, Email: "a@x"}},
	}
	mergeRemoteIntoBundle(local, nil, "p")
	if len(local.Accounts) != 1 {
		t.Fatal("merge with no remote should be a noop")
	}
}

func TestMergeRemoteIntoBundleWrongPassphraseProceedsLocalOnly(t *testing.T) {
	now := time.Now().UTC()
	local := &cloudsync.CloudBundle{
		Accounts: []cloudsync.BundleAccount{{Number: 1, Email: "a@x", UpdatedAtTime: now}},
	}
	remoteBundle := &cloudsync.CloudBundle{
		Accounts: []cloudsync.BundleAccount{{Number: 2, Email: "b@x", UpdatedAtTime: now}},
	}
	remoteCT, _ := cloudsync.Encrypt(remoteBundle, "correct")

	mergeRemoteIntoBundle(local, remoteCT, "wrong")

	if len(local.Accounts) != 1 {
		t.Fatalf("merge with wrong passphrase should fall through to local-only, got %d", len(local.Accounts))
	}
}

func TestNextSeqUsesMaxOfLocalAndRemote(t *testing.T) {
	remoteBundle := &cloudsync.CloudBundle{Seq: 7}
	remoteCT, _ := cloudsync.Encrypt(remoteBundle, "p")

	if got := nextSeq(3, remoteCT, "p"); got != 8 {
		t.Fatalf("expected 8 (max(3,7)+1), got %d", got)
	}
	if got := nextSeq(10, remoteCT, "p"); got != 11 {
		t.Fatalf("expected 11 (max(10,7)+1), got %d", got)
	}
	if got := nextSeq(0, nil, "p"); got != 1 {
		t.Fatalf("expected 1 on fresh device with no remote, got %d", got)
	}
}
