package chat

import (
	"context"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// SearchMessages forwards to the storage's FTS5 index. limit <=0 means
// "use storage default" (currently 50). Results are newest-first.
func (s *Service) SearchMessages(ctx context.Context, accountNum int, query string, limit int) ([]domain.Message, error) {
	_, accountUUID, storage, err := s.openForAccount(ctx, accountNum)
	if err != nil {
		return nil, err
	}
	defer storage.Close()
	return storage.SearchMessages(ctx, accountUUID, query, limit)
}
