package usecase

import "context"

// SnapshotActiveLive copies the currently-active account's live Keychain creds
// into its backup slot. Used before flows that overwrite the live slot outside
// claude-bar's control (notably `claude /login` for adding a new account), so a
// freshly-rotated refresh token is not lost when the live slot is replaced.
//
// No-op when no active account is configured (e.g. registry is empty during the
// very first add). Returns the snapshot error otherwise so callers can decide
// whether to treat it as best-effort.
func (s *Service) SnapshotActiveLive(ctx context.Context) error {
	if err := s.Lock.Acquire(ctx); err != nil {
		return err
	}
	defer s.Lock.Release()

	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return err
	}
	active, ok := reg.Accounts[reg.ActiveAccountNumber]
	if !ok || active == nil {
		return nil
	}
	return s.snapshotLiveCredential(ctx, active)
}
