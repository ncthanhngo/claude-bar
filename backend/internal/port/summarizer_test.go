package port

import "testing"

func TestParseSummarizeJSON(t *testing.T) {
	t.Run("full object", func(t *testing.T) {
		raw := `{"titleVI": "Tiêu đề", "summaryVI": "Tóm tắt", "fullVI": "Đầy đủ"}`
		titleVI, summaryVI, fullVI := ParseSummarizeJSON(raw)
		if titleVI != "Tiêu đề" || summaryVI != "Tóm tắt" || fullVI != "Đầy đủ" {
			t.Errorf("got (%q, %q, %q)", titleVI, summaryVI, fullVI)
		}
	})

	t.Run("markdown-fenced JSON", func(t *testing.T) {
		raw := "```json\n{\"titleVI\": \"T\", \"summaryVI\": \"S\", \"fullVI\": \"F\"}\n```"
		titleVI, summaryVI, fullVI := ParseSummarizeJSON(raw)
		if titleVI != "T" || summaryVI != "S" || fullVI != "F" {
			t.Errorf("got (%q, %q, %q)", titleVI, summaryVI, fullVI)
		}
	})

	t.Run("missing titleVI is backward-safe empty string", func(t *testing.T) {
		raw := `{"summaryVI": "Tóm tắt", "fullVI": "Đầy đủ"}`
		titleVI, summaryVI, fullVI := ParseSummarizeJSON(raw)
		if titleVI != "" {
			t.Errorf("titleVI = %q, want empty when the model omits it", titleVI)
		}
		if summaryVI != "Tóm tắt" || fullVI != "Đầy đủ" {
			t.Errorf("got (%q, %q)", summaryVI, fullVI)
		}
	})

	t.Run("non-JSON response falls back to raw text", func(t *testing.T) {
		raw := "  Just some plain text the model returned instead of JSON.  "
		titleVI, summaryVI, fullVI := ParseSummarizeJSON(raw)
		if titleVI != "" {
			t.Errorf("titleVI = %q, want empty on the plain-text fallback", titleVI)
		}
		if fullVI != "Just some plain text the model returned instead of JSON." {
			t.Errorf("fullVI = %q", fullVI)
		}
		if summaryVI == "" {
			t.Error("summaryVI should not be empty on the plain-text fallback")
		}
	})

	t.Run("empty response yields empty everything", func(t *testing.T) {
		titleVI, summaryVI, fullVI := ParseSummarizeJSON("")
		if titleVI != "" || summaryVI != "" || fullVI != "" {
			t.Errorf("got (%q, %q, %q), want all empty", titleVI, summaryVI, fullVI)
		}
	})
}

func TestBuildSummarizePrompt(t *testing.T) {
	system, user := BuildSummarizePrompt(SummarizeInput{Title: "Hello", Description: "World", URL: "https://example.com"})
	if system == "" {
		t.Error("system prompt should not be empty")
	}
	if user != "Tiêu đề: Hello\nMô tả: World\nNguồn: https://example.com" {
		t.Errorf("user prompt = %q", user)
	}
}
