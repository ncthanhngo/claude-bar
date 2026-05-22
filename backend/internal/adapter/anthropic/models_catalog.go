package anthropic

// ModelSpec describes one assistant model the chat UI can pick. The catalog
// stays in the adapter (it knows the Anthropic model IDs); the UI gets a
// stable list to render and a default to pre-select.
type ModelSpec struct {
	ID              string // Anthropic model ID
	DisplayName     string
	MaxOutputTokens int
	SupportsThinking bool
}

// ModelCatalog is the curated list of Claude models the chat surface exposes.
// Ordered most-capable → fastest so the picker reads top-down by power.
var ModelCatalog = []ModelSpec{
	{
		ID:               "claude-opus-4-7",
		DisplayName:      "Claude Opus 4.7",
		MaxOutputTokens:  8192,
		SupportsThinking: true,
	},
	{
		ID:               "claude-sonnet-4-6",
		DisplayName:      "Claude Sonnet 4.6",
		MaxOutputTokens:  8192,
		SupportsThinking: true,
	},
	{
		ID:               "claude-haiku-4-5-20251001",
		DisplayName:      "Claude Haiku 4.5",
		MaxOutputTokens:  8192,
		SupportsThinking: false,
	},
}

// DefaultModelID is the model picked for new conversations.
const DefaultModelID = "claude-sonnet-4-6"

// ResolveModel returns the spec for an ID, falling back to the default if
// the ID is unknown — keeps the chat surface from breaking when storage
// contains a retired model ID after an upgrade.
func ResolveModel(id string) ModelSpec {
	for _, m := range ModelCatalog {
		if m.ID == id {
			return m
		}
	}
	for _, m := range ModelCatalog {
		if m.ID == DefaultModelID {
			return m
		}
	}
	return ModelCatalog[0]
}
