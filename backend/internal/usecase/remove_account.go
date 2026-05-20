package usecase

import (
	"context"
	"fmt"
)

// RemoveAccount deletes an account from the registry and its backup credentials.
// Refuses to remove the currently-active account (caller must swap first).
func (s *Service) RemoveAccount(ctx context.Context, num int) error {
	if err := s.Lock.Acquire(ctx); err != nil {
		return err
	}
	defer s.Lock.Release()

	reg, err := s.Registry.Load(ctx)
	if err != nil {
		return err
	}
	acc, ok := reg.Accounts[num]
	if !ok {
		return fmt.Errorf("account %d not found", num)
	}
	if reg.ActiveAccountNumber == num {
		return fmt.Errorf("cannot remove active account %d — switch to another first", num)
	}

	if err := s.Backup.Delete(ctx, acc.Number, acc.Email); err != nil {
		return fmt.Errorf("delete backup: %w", err)
	}
	if s.MCPSecrets != nil {
		if err := s.MCPSecrets.DeleteAll(ctx, acc.Number); err != nil {
			return fmt.Errorf("delete mcp secrets: %w", err)
		}
	}
	if s.UsageCache != nil {
		_ = s.UsageCache.Drop(num)
	}
	delete(reg.Accounts, num)
	reg.Sequence = removeInt(reg.Sequence, num)
	return s.Registry.Save(ctx, reg)
}

func removeInt(xs []int, n int) []int {
	out := xs[:0]
	for _, x := range xs {
		if x != n {
			out = append(out, x)
		}
	}
	return out
}
