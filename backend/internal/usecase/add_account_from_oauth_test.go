package usecase

import (
	"context"
	"strings"
	"testing"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

func mkOAuthInput() AddAccountFromOAuthInput {
	return AddAccountFromOAuthInput{
		AccessToken:      "acc-tok",
		RefreshToken:     "ref-tok",
		ExpiresAt:        9_999_999_999_000,
		Scopes:           []string{"user:profile"},
		Email:            "new@example.com",
		OrgUUID:          "org-aaa",
		OrganizationName: "New Org",
	}
}

func mkOAuthService(reg *domain.Registry, bak *pushTestBackupStore) *Service {
	return &Service{
		Backup:   bak,
		Lock:     &pushTestLock{},
		Registry: &pushTestRegistry{reg: reg},
	}
}

func emptyRegistry() *domain.Registry {
	return &domain.Registry{Accounts: map[int]*domain.Account{}, Sequence: []int{}}
}

func TestAddAccountFromOAuth_NewAccount_AssignsNextNumberAndWritesBackup(t *testing.T) {
	reg := emptyRegistry()
	bak := &pushTestBackupStore{blobs: map[int]domain.CredentialBlob{}}
	svc := mkOAuthService(reg, bak)

	res, err := svc.AddAccountFromOAuth(context.Background(), mkOAuthInput())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.WasDuplicate {
		t.Fatalf("new account flagged duplicate")
	}
	if res.Account.Number != 1 {
		t.Fatalf("expected first account number 1, got %d", res.Account.Number)
	}
	if res.Account.Email != "new@example.com" || res.Account.OrganizationUUID != "org-aaa" {
		t.Fatalf("identity not persisted: %+v", res.Account)
	}
	if bak.blobs[1] == "" {
		t.Fatal("backup blob not written for new account")
	}
	// Live/registry-active must be untouched — add never disrupts the session.
	if reg.ActiveAccountNumber != 0 {
		t.Fatalf("add-account changed active to %d, want 0 (unchanged)", reg.ActiveAccountNumber)
	}
}

func TestAddAccountFromOAuth_DuplicateIdentity_RefreshesNoNewSlot(t *testing.T) {
	reg := &domain.Registry{
		Accounts: map[int]*domain.Account{
			1: {Number: 1, Email: "new@example.com", OrganizationUUID: "org-aaa"},
		},
		Sequence: []int{1},
	}
	bak := &pushTestBackupStore{blobs: map[int]domain.CredentialBlob{}}
	svc := mkOAuthService(reg, bak)

	res, err := svc.AddAccountFromOAuth(context.Background(), mkOAuthInput())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !res.WasDuplicate || res.DuplicateOfNum != 1 {
		t.Fatalf("expected duplicate of #1, got dup=%v num=%d", res.WasDuplicate, res.DuplicateOfNum)
	}
	if len(reg.Accounts) != 1 {
		t.Fatalf("duplicate created a second slot: %d accounts", len(reg.Accounts))
	}
	if bak.blobs[1] == "" {
		t.Fatal("duplicate's backup should be refreshed")
	}
}

func TestAddAccountFromOAuth_SameEmailDifferentOrg_CreatesSeparateSlot(t *testing.T) {
	reg := &domain.Registry{
		Accounts: map[int]*domain.Account{
			1: {Number: 1, Email: "new@example.com", OrganizationUUID: "org-OTHER"},
		},
		Sequence: []int{1},
	}
	bak := &pushTestBackupStore{blobs: map[int]domain.CredentialBlob{}}
	svc := mkOAuthService(reg, bak)

	res, err := svc.AddAccountFromOAuth(context.Background(), mkOAuthInput())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.WasDuplicate {
		t.Fatal("same email but different org must NOT be treated as duplicate")
	}
	if len(reg.Accounts) != 2 {
		t.Fatalf("expected a separate slot, got %d accounts", len(reg.Accounts))
	}
}

func TestAddAccountFromOAuth_MissingOrgUuid_Blocks(t *testing.T) {
	in := mkOAuthInput()
	in.OrgUUID = "  "
	svc := mkOAuthService(emptyRegistry(), &pushTestBackupStore{blobs: map[int]domain.CredentialBlob{}})

	_, err := svc.AddAccountFromOAuth(context.Background(), in)
	if err == nil {
		t.Fatal("expected error when orgUuid is missing")
	}
	if !strings.Contains(err.Error(), "organization uuid") {
		t.Fatalf("error should explain the missing org uuid, got: %v", err)
	}
}

func TestAddAccountFromOAuth_MissingTokens_Errors(t *testing.T) {
	in := mkOAuthInput()
	in.RefreshToken = ""
	svc := mkOAuthService(emptyRegistry(), &pushTestBackupStore{blobs: map[int]domain.CredentialBlob{}})

	if _, err := svc.AddAccountFromOAuth(context.Background(), in); err == nil {
		t.Fatal("expected error when refresh token is missing")
	}
}
