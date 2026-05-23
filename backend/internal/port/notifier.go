package port

// NotificationTier mirrors briefing.DeltaTier. Only Critical fires an OS
// notification; Material/Background paint UI badges only.
type NotificationTier string

const (
	NotifyCritical   NotificationTier = "critical"
	NotifyMaterial   NotificationTier = "material"
	NotifyBackground NotificationTier = "background"
)

// Notification is the payload the backend hands the widget for posting.
// The widget side is the only place that talks to UserNotifications.framework;
// the backend never depends on macOS-specific frameworks.
type Notification struct {
	Tier         NotificationTier `json:"tier"`
	Title        string           `json:"title"`
	Body         string           `json:"body"`
	CommitmentID string           `json:"commitmentId,omitempty"`
	DeepLink     string           `json:"deepLink,omitempty"`
}

// Notifier is the boundary between briefing pipeline and macOS user
// notifications. The csw process emits JSON events on stdout; the widget
// hosts the real implementation.
type Notifier interface {
	Post(Notification) error
}
