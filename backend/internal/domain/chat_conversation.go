package domain

import "time"

// Conversation is a chat thread bound hard to one Anthropic account.
// AccountUUID is the partition key for every storage / usecase guard — a
// conversation belonging to account A must never surface when account B is
// active. Title and SystemPrompt are user-editable; Model is captured at
// create time so a mid-conversation provider switch can't poison context.
type Conversation struct {
	ID           string    // UUID v7
	AccountUUID  string    // hard binding to one Anthropic account
	Title        string    // user-editable; auto-derived from first user msg if empty
	Model        string    // e.g. "claude-sonnet-4-6"; locked at create time
	SystemPrompt string    // optional pre-prompt sent on every turn
	CreatedAt    time.Time
	UpdatedAt    time.Time
	Archived     bool
}

// IsForAccount reports whether the conversation belongs to the given account.
// Use at every storage / usecase boundary before returning Conversation data.
func (c Conversation) IsForAccount(accountUUID string) bool {
	return c.AccountUUID == accountUUID
}
