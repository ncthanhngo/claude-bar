package usecase

import (
	"context"
	"errors"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// AddAccountResult tells the caller (UI) whether the snapshot was a duplicate.
type AddAccountResult struct {
	Account        *domain.Account `json:"account"`
	WasDuplicate   bool            `json:"wasDuplicate"`
	DuplicateOfNum int             `json:"duplicateOfNum,omitempty"`
}

// ErrNoLiveCredential means nothing is in the Keychain to snapshot.
var ErrNoLiveCredential = errors.New("no Claude Code login found — log in with `claude /login` first")

// AddAccount snapshots the currently-logged-in Claude account into the registry.
//
// Duplicate detection: if (email, orgUuid) already exists, the snapshot still
// runs (creds + nickname get refreshed) but result.WasDuplicate is true and
// DuplicateOfNum points at the prior entry so the UI can warn.
func (s *Service) AddAccount(ctx context.Context, nickname string) (*AddAccountResult, error) {
	if err := s.Lock.Acquire(ctx); err != nil {
		return nil, err
	}
	defer s.Lock.Release()

	blob, err := s.Live.Read(ctx)
	if err != nil {
		return nil, err
	}
	if blob == "" {
		return nil, ErrNoLiveCredential
	}
	if _, err := blob.Extract(); err != nil {
		return nil, err
	}

	cfg, err := s.Config.Read(ctx)
	if err != nil {
		return nil, err
	}
	if cfg.OAuthAccount == nil || cfg.OAuthAccount.EmailAddress == "" {
		return nil, errors.New("~/.claude.json has no oauthAccount — re-run `claude /login`")
	}

	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return nil, err
	}

	email := cfg.OAuthAccount.EmailAddress
	orgUUID := cfg.OAuthAccount.OrganizationUUID
	dupNum := reg.FindByIdentity(email, orgUUID)

	var acct *domain.Account
	if dupNum != 0 {
		acct = reg.Accounts[dupNum]
		if nickname != "" {
			acct.Nickname = nickname
		}
	} else {
		num := reg.NextAccountNumber()
		acct = &domain.Account{
			Number:           num,
			Email:            email,
			OrganizationName: cfg.OAuthAccount.OrganizationName,
			OrganizationUUID: orgUUID,
			Nickname:         nickname,
			CreatedAt:        time.Now().UTC(),
		}
		reg.Accounts[num] = acct
		reg.Sequence = append(reg.Sequence, num)
	}
	reg.ActiveAccountNumber = acct.Number

	if err := s.Backup.Write(ctx, acct.Number, acct.Email, blob); err != nil {
		return nil, err
	}
	if err := s.Registry.Save(ctx, reg); err != nil {
		return nil, err
	}

	return &AddAccountResult{
		Account:        acct,
		WasDuplicate:   dupNum != 0,
		DuplicateOfNum: dupNum,
	}, nil
}
