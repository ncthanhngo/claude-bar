package domain

// ContentBlockKind is the discriminator for ContentBlock's union shape. Go has
// no native sum types so we use one struct with a Kind tag — `Validate` checks
// the right subset of fields are populated. Adapter (Anthropic JSON) and
// storage (SQLite rows) both encode/decode through this single shape.
type ContentBlockKind string

const (
	BlockText     ContentBlockKind = "text"
	BlockImage    ContentBlockKind = "image"
	BlockDocument ContentBlockKind = "document"
	BlockToolUse  ContentBlockKind = "tool_use"
	BlockThinking ContentBlockKind = "thinking"
)

// ContentBlock is one segment inside a Message. Image / document blocks
// reference an Attachment by ID rather than inlining bytes — the encoded
// file lives on disk under the per-account attachment dir.
type ContentBlock struct {
	Kind ContentBlockKind

	// Populated for BlockText / BlockThinking.
	Text string

	// Populated for BlockImage / BlockDocument.
	AttachmentID string
	MediaType    string // "image/png" | "application/pdf" | …

	// Populated for BlockToolUse. ToolInput is treated as opaque JSON by the
	// adapter — domain stays unaware of any specific tool schema.
	ToolName  string
	ToolInput map[string]any

	// Base64Data is a transient field — populated by the usecase right before
	// handing the block to ChatClient.Stream (it reads + decrypts the on-disk
	// attachment file and fills it). Never stored on disk, never returned
	// from storage. The adapter consumes and discards.
	Base64Data string `json:"-"`
}

// Validate reports whether the block's populated fields match its Kind.
// Returns nil on success. Storage / adapter call this before persisting or
// transmitting so invalid blocks never reach Anthropic.
func (b ContentBlock) Validate() error {
	switch b.Kind {
	case BlockText, BlockThinking:
		if b.Text == "" {
			return ErrInvalidContentBlock
		}
	case BlockImage, BlockDocument:
		if b.AttachmentID == "" || b.MediaType == "" {
			return ErrInvalidContentBlock
		}
	case BlockToolUse:
		if b.ToolName == "" {
			return ErrInvalidContentBlock
		}
	default:
		return ErrInvalidContentBlock
	}
	return nil
}
