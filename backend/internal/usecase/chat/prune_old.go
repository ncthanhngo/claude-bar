package chat

import (
	"context"
	"fmt"
	"time"
)

// PruneOlderThan deletes every conversation in the active account whose
// `updatedAt` is older than the cutoff. Returns the number of deletions
// performed. Caller decides the policy (Settings toggle: off / 30 / 60 /
// 90 days); this function just executes.
func (s *Service) PruneOlderThan(ctx context.Context, accountNum int, age time.Duration) (int, error) {
	if age <= 0 {
		return 0, fmt.Errorf("chat.Prune: non-positive age")
	}
	_, accountUUID, storage, err := s.openForAccount(ctx, accountNum)
	if err != nil {
		return 0, err
	}
	defer storage.Close()

	convs, err := storage.ListConversations(ctx, accountUUID)
	if err != nil {
		return 0, err
	}
	cutoff := s.Now().Add(-age)
	deleted := 0
	for _, c := range convs {
		if c.UpdatedAt.Before(cutoff) {
			if err := storage.DeleteConversation(ctx, accountUUID, c.ID); err != nil {
				return deleted, fmt.Errorf("delete %s: %w", c.ID, err)
			}
			deleted++
		}
	}
	return deleted, nil
}
