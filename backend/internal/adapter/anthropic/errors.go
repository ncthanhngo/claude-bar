package anthropic

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
)

// httpErrorEvent wraps a non-2xx response so the caller (ChatClient.Stream)
// can turn it into a domain.ChatStreamEvent without re-reading the body.
// Used only for 429 / 5xx pre-stream failures; 401 is handled separately.
type httpErrorEvent struct {
	Code        string // "rate_limited" | "overloaded" | "auth" | "bad_request" | "network" | "unknown"
	Message     string
	RetryAfterS int
}

// Error makes httpErrorEvent usable as a Go error (returned alongside the
// channel-less code path so the caller can branch on errors.As).
func (e *httpErrorEvent) Error() string {
	return fmt.Sprintf("anthropic %s: %s", e.Code, e.Message)
}

// decodeErrorBody reads a non-2xx response and classifies it. Best-effort —
// if the body isn't the expected JSON shape we still produce a coherent
// httpErrorEvent so the UI doesn't see "unknown" everywhere.
func decodeErrorBody(resp *http.Response) *httpErrorEvent {
	raw, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()

	ev := &httpErrorEvent{
		Code:    httpStatusToCode(resp.StatusCode),
		Message: string(raw),
	}

	// Parse the conventional Anthropic envelope: { "type":"error", "error":{...} }
	var env struct {
		Error sseError `json:"error"`
	}
	if err := json.Unmarshal(raw, &env); err == nil && env.Error.Type != "" {
		ev.Code = classifyErrorType(env.Error.Type)
		if env.Error.Message != "" {
			ev.Message = env.Error.Message
		}
	}
	if resp.StatusCode == http.StatusTooManyRequests {
		ev.Code = "rate_limited"
		if h := resp.Header.Get("Retry-After"); h != "" {
			if n, err := strconv.Atoi(h); err == nil {
				ev.RetryAfterS = n
			}
		}
	}
	return ev
}

// httpStatusToCode is the fallback classifier used when the body doesn't
// carry an Anthropic-shaped error envelope (e.g. CloudFront 502 page).
func httpStatusToCode(status int) string {
	switch {
	case status == http.StatusTooManyRequests:
		return "rate_limited"
	case status == http.StatusUnauthorized, status == http.StatusForbidden:
		return "auth"
	case status == http.StatusBadRequest:
		return "bad_request"
	case status >= 500:
		return "overloaded"
	default:
		return "unknown"
	}
}
