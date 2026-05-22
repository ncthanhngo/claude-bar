package domain

import "errors"

// Chat-related sentinel errors. Usecases branch on these via errors.Is rather
// than string-matching adapter messages — keeps the boundary clean and lets
// the UI layer surface a specific recovery path per condition.
var (
	// ErrConversationNotFound: requested conversation ID does not exist for
	// the active account. UI shows "Đoạn chat này không còn nữa".
	ErrConversationNotFound = errors.New("chat: conversation not found")

	// ErrAccountMismatch: storage returned a row whose AccountUUID doesn't
	// match the caller's account. Defensive — should never happen if the
	// per-account DB partitioning works. Logged loudly; UI shows generic error.
	ErrAccountMismatch = errors.New("chat: conversation belongs to another account")

	// ErrTokenRefreshFailed: OAuth refresh hit a non-transient failure
	// (revoked / 400 grant). UI prompts re-login for this account.
	ErrTokenRefreshFailed = errors.New("chat: token refresh failed; re-login required")

	// ErrAttachmentTooLarge: file rejected pre-upload by size budget. Caller
	// provides the limit so the UI message can quote it.
	ErrAttachmentTooLarge = errors.New("chat: attachment exceeds size limit")

	// ErrStreamCancelled: caller cancelled the context mid-stream. Distinct
	// from a real upstream failure so the UI doesn't show an error banner.
	ErrStreamCancelled = errors.New("chat: stream cancelled by caller")

	// ErrInvalidContentBlock: ContentBlock.Validate failed — Kind doesn't
	// match populated fields. Always a programmer bug; never user-facing.
	ErrInvalidContentBlock = errors.New("chat: invalid content block")
)
