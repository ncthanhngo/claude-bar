package briefing

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

func TestIntervalRunnerCallsTickRepeatedly(t *testing.T) {
	var calls int32
	r := &IntervalRunner{
		Interval: 20 * time.Millisecond,
		Tick: func(ctx context.Context) error {
			atomic.AddInt32(&calls, 1)
			return nil
		},
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := r.Start(ctx); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	cancel()
	r.Stop()
	got := atomic.LoadInt32(&calls)
	if got < 3 {
		t.Errorf("expected ≥3 ticks in 100ms with 20ms interval, got %d", got)
	}
}

func TestIntervalRunnerBackoffOnFailures(t *testing.T) {
	d := backoffDuration(time.Minute, 3, 30*time.Minute)
	if d != 4*time.Minute {
		t.Errorf("3-failure backoff = %v, want 4m (1m × 2^2)", d)
	}
	d = backoffDuration(time.Minute, 10, 30*time.Minute)
	if d != 30*time.Minute {
		t.Errorf("10-failure backoff should cap at max, got %v", d)
	}
}

func TestIntervalRunnerRefusesDoubleStart(t *testing.T) {
	r := &IntervalRunner{
		Interval: time.Second,
		Tick:     func(context.Context) error { return nil },
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := r.Start(ctx); err != nil {
		t.Fatal(err)
	}
	if err := r.Start(ctx); !errors.Is(err, ErrIntervalRunnerAlreadyRunning) {
		t.Errorf("second Start returned %v, want ErrIntervalRunnerAlreadyRunning", err)
	}
	r.Stop()
}

func TestIntervalRunnerRequiresTick(t *testing.T) {
	r := &IntervalRunner{Interval: time.Second}
	if err := r.Start(context.Background()); err == nil {
		t.Errorf("missing Tick should error")
	}
}
