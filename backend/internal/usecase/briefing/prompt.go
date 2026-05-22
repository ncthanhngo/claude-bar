package briefing

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// BriefingPayload is the JSON shape Claude returns. We compute IDs / stats /
// done flags ourselves, so Claude only ranks + summarizes.
type BriefingPayload struct {
	Hero    PayloadHero    `json:"hero"`
	Actions []PayloadAction `json:"actions"`
	Calendar []PayloadCal   `json:"calendar"`
}

type PayloadHero struct {
	Eyebrow     string `json:"eyebrow"`
	Title       string `json:"title"`
	FocusBadge  string `json:"focusBadge"`
	FocusBody   string `json:"focusBody"`
	CountNumber int    `json:"countNumber"`
	CountLabel  string `json:"countLabel"`
}

type PayloadAction struct {
	Priority     string `json:"priority"`
	Title        string `json:"title"`
	Source       string `json:"source"`
	SourceMeta   string `json:"sourceMeta"`
	Context      string `json:"context"`
	Deadline     string `json:"deadline"`
	DeadlineHint string `json:"deadlineHint"`
	DeadlineTone string `json:"deadlineTone"`
	DeepLink     string `json:"deepLink,omitempty"`
}

type PayloadCal struct {
	Time     string `json:"time"`
	EndTime  string `json:"endTime"`
	State    string `json:"state"`
	Title    string `json:"title"`
	Subtitle string `json:"subtitle"`
	Flag     string `json:"flag,omitempty"`
}

// buildPrompt returns the full Vietnamese system+user prompt fed to Claude.
// Embeds the raw source data as JSON. `userPrompt` (optional, may be empty)
// is injected as an early section so the model treats it as priority
// instructions over the generic ranking rules.
func buildPrompt(raw *RawSourceData, today time.Time, userPrompt string) string {
	rawJSON, _ := json.MarshalIndent(raw, "", "  ")
	weekday := vnWeekday(today)
	dateStr := today.Format("02/01/2006")

	var b strings.Builder
	b.WriteString("Bạn là trợ lý cá nhân biên tập daily briefing tiếng Việt cho dân kỹ thuật. ")
	b.WriteString("Đọc dữ liệu thô từ 4 nguồn (Gmail/GCal/ClickUp/Slack) và sinh JSON briefing thuần.\n\n")

	b.WriteString(fmt.Sprintf("# Bối cảnh hôm nay\n- Ngày: %s, %s\n- Múi giờ: Asia/Saigon\n\n", weekday, dateStr))

	if up := strings.TrimSpace(userPrompt); up != "" {
		b.WriteString("# Ưu tiên người dùng\n")
		b.WriteString("Hướng dẫn dưới đây do user viết — luôn tôn trọng khi rank actions:\n\n")
		b.WriteString(up)
		b.WriteString("\n\n")
	}

	b.WriteString("# Yêu cầu output\n")
	b.WriteString("Trả về DUY NHẤT một JSON object hợp lệ theo schema dưới. KHÔNG markdown, KHÔNG ``` fence, KHÔNG bình luận thêm.\n\n")
	b.WriteString(promptSchema)
	b.WriteString("\n\n")

	b.WriteString("# Nguyên tắc rank\n")
	b.WriteString("- Tối đa 7 actions, sắp theo độ khẩn cấp. Top 1-3 = 'urgent' (deadline trong 24h, VIP, overdue). Tiếp 2 = 'important'. Còn lại = 'normal'.\n")
	b.WriteString("- 'source' chỉ thuộc: email|task|slack|meet. 'sourceMeta' ngắn như 'email · VIP' hoặc 'task · ClickUp'.\n")
	b.WriteString("- 'context' = 1 câu italic ngắn (≤80 ký tự), trích đoạn tin nhắn/mô tả thật.\n")
	b.WriteString("- 'deadline' = chuỗi thân thiện tiếng Việt: 'trước 17:00', 'due hôm nay', 'trong 2h', 'hôm nay', 'trong tuần'.\n")
	b.WriteString("- 'deadlineTone' = urgent|soon|normal|done.\n")
	b.WriteString("- Hero title = serif italic câu nhấn: 'Bảy việc đang chờ — một cảnh báo cần xử trí.' (đếm thực tế).\n")
	b.WriteString("- FocusBody = 1 câu hành động về item #1, có chữ in đậm (bằng cách markdown ** nếu cần).\n")
	b.WriteString("- Calendar tối đa 5 events, sắp theo giờ. State: 'done' (đã qua), 'now' (event hiện tại / sắp tới), 'next' (sau đó).\n")
	b.WriteString("- Bỏ qua noise: newsletter, automated GitHub digest, Slack channel-wide announcement không liên quan.\n")
	b.WriteString("- Ngôn ngữ: tiếng Việt tự nhiên, KHÔNG dịch máy. Tên riêng giữ nguyên.\n\n")

	b.WriteString("# Dữ liệu thô\n")
	b.WriteString("```json\n")
	b.Write(rawJSON)
	b.WriteString("\n```\n\n")
	b.WriteString("Hãy sinh JSON briefing ngay bây giờ.")

	return b.String()
}

const promptSchema = `{
  "hero": {
    "eyebrow": "Hôm nay bạn cần làm",
    "title": "...",
    "focusBadge": "trước tiên",
    "focusBody": "...",
    "countNumber": <int>,
    "countLabel": "việc · X urgent · Y soon"
  },
  "actions": [
    {
      "priority": "urgent|important|normal",
      "title": "...",
      "source": "email|task|slack|meet",
      "sourceMeta": "...",
      "context": "...",
      "deadline": "...",
      "deadlineHint": "...",
      "deadlineTone": "urgent|soon|normal|done",
      "deepLink": ""
    }
  ],
  "calendar": [
    {"time":"HH:MM","endTime":"HH:MM","state":"done|now|next","title":"...","subtitle":"...","flag":""}
  ]
}`

func vnWeekday(t time.Time) string {
	names := []string{"Chủ nhật", "Thứ hai", "Thứ ba", "Thứ tư", "Thứ năm", "Thứ sáu", "Thứ bảy"}
	return names[t.Weekday()]
}
