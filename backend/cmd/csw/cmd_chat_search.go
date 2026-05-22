package main

import (
	"context"
	"errors"
	"flag"

	"github.com/soi/claude-swap-widget/backend/internal/usecase/chat"
)

// runChatSearch runs FTS5 over the active account's messages and prints
// matching messages as JSON. Used by the widget's rail search bar.
func runChatSearch(ctx context.Context, svc *chat.Service, accountNum int, args []string) error {
	fs := flag.NewFlagSet("search", flag.ContinueOnError)
	query := fs.String("query", "", "FTS5 query")
	limit := fs.Int("limit", 50, "max results")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *query == "" {
		return errors.New("--query is required")
	}

	msgs, err := svc.SearchMessages(ctx, accountNum, *query, *limit)
	if err != nil {
		return err
	}
	out := make([]messageOut, 0, len(msgs))
	for _, m := range msgs {
		out = append(out, toMsgOut(m))
	}
	return writeJSON(out)
}
