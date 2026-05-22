package anthropic

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/soi/claude-swap-widget/backend/internal/domain"
)

// Mock Anthropic SSE stream. Covers message_start (usage seed), 3 text_delta
// chunks, a thinking_delta, message_delta with usage + stop_reason, then
// message_stop terminator. Ping line is silently ignored.
const fixtureSSE = `event: message_start
data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":42}}}

event: ping
data: {"type":"ping"}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello "}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"!"}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"weighing options"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn","usage":{"output_tokens":17}}}

event: message_stop
data: {"type":"message_stop"}

`

func TestParseSSE_HappyPath(t *testing.T) {
	out := make(chan domain.ChatStreamEvent, 32)
	parseSSE(context.Background(), strings.NewReader(fixtureSSE), out)
	close(out)

	var events []domain.ChatStreamEvent
	for ev := range out {
		events = append(events, ev)
	}
	if len(events) != 6 {
		t.Fatalf("want 6 events, got %d: %+v", len(events), events)
	}

	wantKinds := []domain.StreamEventKind{
		domain.StreamUsage,        // message_start usage seed
		domain.StreamTextDelta,    // "Hello "
		domain.StreamTextDelta,    // "world"
		domain.StreamTextDelta,    // "!"
		domain.StreamThinkingDelta,
		domain.StreamDone,
	}
	for i, want := range wantKinds {
		if events[i].Kind != want {
			t.Errorf("event[%d] kind = %q, want %q", i, events[i].Kind, want)
		}
	}
	if got := events[1].Text + events[2].Text + events[3].Text; got != "Hello world!" {
		t.Errorf("text deltas joined = %q, want %q", got, "Hello world!")
	}
	if events[4].Text != "weighing options" {
		t.Errorf("thinking delta = %q", events[4].Text)
	}
	if events[5].StopReason != "end_turn" {
		t.Errorf("stop_reason = %q", events[5].StopReason)
	}
	if events[5].OutputTokens != 17 {
		t.Errorf("output_tokens = %d, want 17", events[5].OutputTokens)
	}
	if events[0].InputTokens != 42 {
		t.Errorf("message_start input_tokens = %d, want 42", events[0].InputTokens)
	}
}

func TestParseSSE_ErrorEvent(t *testing.T) {
	const fixture = `event: error
data: {"type":"error","error":{"type":"overloaded_error","message":"system is overloaded"}}

`
	out := make(chan domain.ChatStreamEvent, 4)
	parseSSE(context.Background(), strings.NewReader(fixture), out)
	close(out)

	ev, ok := <-out
	if !ok {
		t.Fatal("expected one error event")
	}
	if ev.Kind != domain.StreamError {
		t.Fatalf("kind = %q", ev.Kind)
	}
	if ev.ErrorCode != "overloaded" {
		t.Errorf("code = %q, want overloaded", ev.ErrorCode)
	}
}

func TestParseSSE_ContextCancel(t *testing.T) {
	// Slow-reader fixture: keep sending text_delta forever. Cancel ctx and
	// ensure the parser returns within a short deadline.
	r, w := newPipe()
	go func() {
		for i := 0; i < 1000; i++ {
			_, _ = w.Write([]byte(`data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}` + "\n\n"))
		}
		_ = w.Close()
	}()
	ctx, cancel := context.WithCancel(context.Background())
	out := make(chan domain.ChatStreamEvent, 4)

	done := make(chan struct{})
	go func() {
		parseSSE(ctx, r, out)
		close(done)
	}()

	cancel()
	select {
	case <-done:
	case <-time.After(200 * time.Millisecond):
		t.Fatal("parseSSE did not return within 200ms after ctx cancel")
	}
}
