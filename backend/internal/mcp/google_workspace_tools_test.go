package mcp

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestExtractGmailPlainText(t *testing.T) {
	encoded := base64.RawURLEncoding.EncodeToString([]byte("hello from gmail"))
	msg := gmailMessage{
		Payload: gmailPayload{
			MimeType: "multipart/alternative",
			Parts: []gmailPayload{{
				MimeType: "text/plain",
				Body: struct {
					Data string `json:"data"`
				}{Data: encoded},
			}},
		},
	}
	got := extractGmailPlainText(msg.Payload)
	if strings.TrimSpace(got) != "hello from gmail" {
		t.Fatalf("unexpected body %q", got)
	}
}

func TestGmailHeaderMapKeepsUsefulHeaders(t *testing.T) {
	msg := gmailMessage{Payload: gmailPayload{Headers: []gmailHeader{
		{Name: "From", Value: "a@example.com"},
		{Name: "Subject", Value: "Hello"},
		{Name: "Received", Value: "internal"},
	}}}
	headers := msg.headerMap()
	if headers["From"] != "a@example.com" || headers["Subject"] != "Hello" {
		t.Fatalf("missing useful headers: %+v", headers)
	}
	if _, ok := headers["Received"]; ok {
		t.Fatalf("should not include noisy Received header: %+v", headers)
	}
}
