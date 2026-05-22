package domain

import "time"

// AttachmentKind narrows what the chat composer / storage layers may accept.
// Anything else gets rejected at the boundary.
type AttachmentKind string

const (
	AttachImage AttachmentKind = "image"
	AttachPDF   AttachmentKind = "pdf"
	AttachText  AttachmentKind = "text"
)

// Attachment is the on-disk representation of an uploaded file. The file is
// encrypted (XChaCha20-Poly1305) under the per-account chat DB key; FilePath
// points at the .enc file and NonceHex is the 24-byte hex nonce needed for
// decryption. MessageID is empty until the parent message is persisted.
type Attachment struct {
	ID             string
	ConversationID string
	MessageID      string // empty until the owning message saves
	Kind           AttachmentKind
	Filename       string
	MediaType      string // "image/png" | "application/pdf" | "text/markdown" …
	SizeBytes      int64
	FilePath       string // absolute path to the .enc file on disk
	NonceHex       string // 48-char hex (24 bytes) for XChaCha20-Poly1305

	CreatedAt time.Time
}
