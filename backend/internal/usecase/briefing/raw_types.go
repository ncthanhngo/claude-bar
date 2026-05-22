package briefing

import "time"

// RawSourceData is the unified payload returned by Orchestrator.Fetch.
// All fields are best-effort: a failing source records a string in Errors
// and leaves the corresponding slice nil/empty.
type RawSourceData struct {
	AccountNumber int                  `json:"accountNumber"`
	FetchedAt     time.Time            `json:"fetchedAt"`
	Gmail         []GmailItem          `json:"gmail"`
	GCal          []CalItem            `json:"gcal"`
	ClickUp       []TaskItem           `json:"clickup"`
	Slack         []SlackItem          `json:"slack"`
	Errors        map[string]string    `json:"errors"`        // source name → redacted error
	Health        map[string]string    `json:"health"`        // source → "ok"|"down"|"unauthorized"
}

// GmailItem is one row from Gmail search.
type GmailItem struct {
	ID         string    `json:"id"`
	ThreadID   string    `json:"threadId"`
	From       string    `json:"from"`
	FromEmail  string    `json:"fromEmail"`
	Subject    string    `json:"subject"`
	Snippet    string    `json:"snippet"`
	ReceivedAt time.Time `json:"receivedAt"`
	IsStarred  bool      `json:"isStarred"`
	IsUnread   bool      `json:"isUnread"`
	IsVIP      bool      `json:"isVip"` // populated downstream from settings VIP list
}

// CalItem is one Google Calendar event.
type CalItem struct {
	ID          string    `json:"id"`
	Summary     string    `json:"summary"`
	Start       time.Time `json:"start"`
	End         time.Time `json:"end"`
	IsAllDay    bool      `json:"isAllDay"`
	Location    string    `json:"location"`
	Attendees   int       `json:"attendees"`
	IsRecurring bool      `json:"isRecurring"`
	Status      string    `json:"status"` // confirmed | tentative | cancelled
}

// TaskItem is one ClickUp task.
type TaskItem struct {
	ID         string    `json:"id"`
	Name       string    `json:"name"`
	ListName   string    `json:"listName"`
	Status     string    `json:"status"`
	Priority   string    `json:"priority"` // urgent|high|normal|low|""
	Due        time.Time `json:"due"`      // zero = no due
	URL        string    `json:"url"`
	IsClosed   bool      `json:"isClosed"`
	AssignedMe bool      `json:"assignedMe"`
}

// SlackItem is one Slack message (search result row).
type SlackItem struct {
	Channel   string    `json:"channel"`
	ChannelID string    `json:"channelId"`
	User      string    `json:"user"`
	Text      string    `json:"text"`
	TS        string    `json:"ts"`       // "1700000000.123456"
	ThreadTS  string    `json:"threadTs"` // "" if not in thread
	Posted    time.Time `json:"posted"`
	IsMention bool      `json:"isMention"`
	IsDM      bool      `json:"isDm"`
	Permalink string    `json:"permalink"`
}
