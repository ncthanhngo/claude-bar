package main

import (
	"context"
	"errors"
	"fmt"

	"github.com/soi/claude-swap-widget/backend/internal/adapter/anthropic"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/chatstorage"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/keychain"
	"github.com/soi/claude-swap-widget/backend/internal/adapter/oauth"
	"github.com/soi/claude-swap-widget/backend/internal/port"
	"github.com/soi/claude-swap-widget/backend/internal/usecase"
	"github.com/soi/claude-swap-widget/backend/internal/usecase/chat"
)

// runChat dispatches `csw chat <conversations|send|attach|search>`.
func runChat(ctx context.Context, svc *usecase.Service, args []string) error {
	if len(args) == 0 {
		return errors.New("usage: csw chat <conversations|send|attach|search> ...")
	}
	chatSvc, err := buildChatService(svc)
	if err != nil {
		return err
	}
	accountNum, err := activeAccountNumber(ctx, svc)
	if err != nil {
		return err
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "conversations":
		return runChatConversations(ctx, chatSvc, accountNum, rest)
	case "send":
		return runChatSend(ctx, chatSvc, accountNum, rest)
	case "attach":
		return runChatAttach(ctx, chatSvc, accountNum, rest)
	case "search":
		return runChatSearch(ctx, chatSvc, accountNum, rest)
	default:
		return fmt.Errorf("unknown chat subcommand: %s", sub)
	}
}

// buildChatService wires the chat usecase service from the existing csw
// adapters. We re-use service.Live / Refresh / Config / Registry rather
// than re-instantiating them so the same Keychain + on-disk state backs
// both the swap flow and the chat flow.
func buildChatService(svc *usecase.Service) (*chat.Service, error) {
	tokenProvider := oauth.NewTokenProvider(svc.Live, svc.Refresh, svc.Config, svc.Registry)
	chatClient := anthropic.NewChatClient()
	chatDBKeyStore := keychain.NewChatDBKeyStore()

	openStorage := func(ctx context.Context, accountUUID string) (port.ChatStorage, error) {
		return chatstorage.Open(ctx, accountUUID, chatDBKeyStore, "", "")
	}
	return chat.NewService(tokenProvider, chatClient, openStorage), nil
}

// activeAccountNumber returns the currently-active account number from the
// registry. Chat commands all operate on the active account; switching
// requires `csw switch <num>` first (existing behaviour).
func activeAccountNumber(ctx context.Context, svc *usecase.Service) (int, error) {
	reg, err := svc.Registry.Load(ctx)
	if err != nil {
		return 0, fmt.Errorf("load registry: %w", err)
	}
	if reg.ActiveAccountNumber == 0 {
		return 0, errors.New("no active account; run `csw switch <num>` first")
	}
	return reg.ActiveAccountNumber, nil
}
