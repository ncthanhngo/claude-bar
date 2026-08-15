package port

import (
	"context"
	"encoding/json"
	"strings"
)

// SummarizeOpts controls provider/model/target language for one Summarize
// call. Provider is informational (adapters know their own identity);
// Model is required for the Ollama adapter and ignored by the Anthropic
// one, which pins its own small/cheap model internally.
type SummarizeOpts struct {
	Provider   string
	Model      string
	TargetLang string
}

// SummarizeInput is the minimal English source text handed to a Summarizer
// — shared by news items and GitHub repo descriptions alike.
type SummarizeInput struct {
	Title       string
	Description string
	URL         string
}

// Summarizer produces a concise Vietnamese title, a one-line Vietnamese
// summary, and a fuller Vietnamese translation/summary for one item.
// Implementations: adapter/ollama (local, default) and adapter/anthropic
// (Claude fallback, reuses the OAuth chat path). usecase/news.ProviderRouter
// selects between the two per NewsConfig.
type Summarizer interface {
	Summarize(ctx context.Context, item SummarizeInput, opts SummarizeOpts) (titleVI, summaryVI, fullVI string, err error)
}

// summarizePrompt instructs the model to translate+condense an English news
// item into Vietnamese, returning ONLY a JSON object so both the local and
// hosted providers can share one response parser (ParseSummarizeJSON). The
// grounding instructions ("only the text given", "summarize from the title
// alone" when the description is thin) exist because small local models
// otherwise tend to invent details not present in the source snippet.
const summarizePrompt = `Bạn là biên tập viên tin công nghệ. Chỉ dựa vào tiêu đề và mô tả tiếng Anh dưới đây — không suy đoán, không bịa thêm chi tiết không có trong văn bản. Nếu phần mô tả quá ngắn hoặc không có, hãy tóm tắt dựa trên tiêu đề. Trả lời DUY NHẤT một đối tượng JSON hợp lệ, mọi giá trị đều bằng tiếng Việt (không lẫn tiếng Anh), với đúng ba khoá, không thêm văn bản nào khác:
{"titleVI": "tiêu đề ngắn gọn bằng tiếng Việt", "summaryVI": "một câu tóm tắt ngắn gọn bằng tiếng Việt (dưới 25 từ)", "fullVI": "bản dịch/tóm tắt đầy đủ hơn bằng tiếng Việt (2-4 câu), chỉ dựa trên nội dung đã cho"}`

// BuildSummarizePrompt renders the (system, user) prompt pair for item. Both
// adapters share this so the JSON-only response contract stays identical
// regardless of which provider answers it.
func BuildSummarizePrompt(item SummarizeInput) (system, user string) {
	var b strings.Builder
	b.WriteString("Tiêu đề: ")
	b.WriteString(item.Title)
	if item.Description != "" {
		b.WriteString("\nMô tả: ")
		b.WriteString(item.Description)
	}
	if item.URL != "" {
		b.WriteString("\nNguồn: ")
		b.WriteString(item.URL)
	}
	return summarizePrompt, b.String()
}

// ParseSummarizeJSON extracts {"titleVI","summaryVI","fullVI"} from a model
// response that may carry stray whitespace or markdown fencing around the
// JSON object. A missing/empty titleVI is returned as "" (backward-safe:
// callers must not assume it's ever populated). Falls back to treating the
// whole trimmed response as fullVI (and a truncated prefix as summaryVI,
// titleVI left empty) when no valid JSON object is present — keeps the
// pipeline resilient to a model that doesn't follow instructions exactly,
// rather than dropping the item entirely.
func ParseSummarizeJSON(raw string) (titleVI, summaryVI, fullVI string) {
	trimmed := strings.TrimSpace(raw)
	if start, end := strings.Index(trimmed, "{"), strings.LastIndex(trimmed, "}"); start >= 0 && end > start {
		var parsed struct {
			TitleVI   string `json:"titleVI"`
			SummaryVI string `json:"summaryVI"`
			FullVI    string `json:"fullVI"`
		}
		if err := json.Unmarshal([]byte(trimmed[start:end+1]), &parsed); err == nil &&
			(parsed.TitleVI != "" || parsed.SummaryVI != "" || parsed.FullVI != "") {
			titleVI, summaryVI, fullVI = parsed.TitleVI, parsed.SummaryVI, parsed.FullVI
			if summaryVI == "" {
				summaryVI = truncateRunes(fullVI, 120)
			}
			if fullVI == "" {
				fullVI = summaryVI
			}
			return titleVI, summaryVI, fullVI
		}
	}
	fullVI = trimmed
	summaryVI = truncateRunes(trimmed, 120)
	return "", summaryVI, fullVI
}

func truncateRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}

// ArticleTranslateInput is the source text for a full on-demand article
// translation (`csw news article`) — distinct from SummarizeInput because it
// carries the whole extracted article body (up to ~8000 chars) rather than a
// short RSS description, and expects a full paragraph-preserving
// translation instead of a condensed summary.
type ArticleTranslateInput struct {
	Title string
	Body  string
}

// ArticleTranslator is the optional capability a Summarizer implementation
// may expose to translate a full article body to Vietnamese, preserving
// paragraph breaks, rather than condensing it into a short summary.
// Implementations: adapter/ollama.Client, adapter/anthropic.Summarizer.
// usecase/news.ProviderRouter type-asserts for it the same way it does for
// modelResolver/namedModel.
type ArticleTranslator interface {
	TranslateArticle(ctx context.Context, item ArticleTranslateInput, opts SummarizeOpts) (titleVI, contentVI string, err error)
}

// articleTranslatePrompt instructs the model to translate a FULL article
// body to Vietnamese, preserving every paragraph rather than condensing —
// the opposite instruction of summarizePrompt above.
const articleTranslatePrompt = `Bạn là biên dịch viên tin công nghệ. Dịch TOÀN BỘ nội dung bài viết tiếng Anh dưới đây sang tiếng Việt — dịch đầy đủ, không tóm tắt, không bỏ sót đoạn nào, không bịa thêm chi tiết không có trong văn bản. Giữ nguyên cấu trúc đoạn văn của bản gốc. Trả lời DUY NHẤT một đối tượng JSON hợp lệ, mọi giá trị đều bằng tiếng Việt (không lẫn tiếng Anh), với đúng hai khoá, không thêm văn bản nào khác:
{"titleVI": "tiêu đề bằng tiếng Việt", "contentVI": "toàn bộ nội dung đã dịch sang tiếng Việt; các đoạn văn cách nhau bằng chính xác hai ký tự xuống dòng liên tiếp"}`

// BuildTranslatePrompt renders the (system, user) prompt pair for a full
// article translation. Shared by both adapters so the JSON-only response
// contract stays identical regardless of which provider answers it.
func BuildTranslatePrompt(item ArticleTranslateInput) (system, user string) {
	var b strings.Builder
	b.WriteString("Tiêu đề: ")
	b.WriteString(item.Title)
	b.WriteString("\nNội dung:\n")
	b.WriteString(item.Body)
	return articleTranslatePrompt, b.String()
}

// ParseTranslateJSON extracts {"titleVI","contentVI"} from a model response
// that may carry stray whitespace or markdown fencing around the JSON
// object. Falls back to treating the whole trimmed response as contentVI
// (titleVI left empty) when no valid JSON object is present — keeps the
// pipeline resilient to a model that doesn't follow instructions exactly.
func ParseTranslateJSON(raw string) (titleVI, contentVI string) {
	trimmed := strings.TrimSpace(raw)
	if start, end := strings.Index(trimmed, "{"), strings.LastIndex(trimmed, "}"); start >= 0 && end > start {
		var parsed struct {
			TitleVI   string `json:"titleVI"`
			ContentVI string `json:"contentVI"`
		}
		if err := json.Unmarshal([]byte(trimmed[start:end+1]), &parsed); err == nil &&
			(parsed.TitleVI != "" || parsed.ContentVI != "") {
			return parsed.TitleVI, parsed.ContentVI
		}
	}
	return "", trimmed
}
