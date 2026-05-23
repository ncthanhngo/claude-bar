package briefing

import (
	"context"
	"errors"
	"sync"
	"time"
)

// IntervalTickFn is the work the runner performs each tick — typically the
// briefing orchestrator. Returns the produced briefing for delta-diffing
// downstream. Errors are swallowed by the runner with a backoff applied.
type IntervalTickFn func(ctx context.Context) error

// IntervalRunner ticks at a user-configured cadence, applies exponential
// backoff on consecutive failures, and exits cleanly on context cancel.
// It does NOT itself classify deltas or post notifications — that's done by
// the caller, after IntervalTickFn returns.
type IntervalRunner struct {
	Interval time.Duration
	Tick     IntervalTickFn
	MaxBackoff time.Duration

	mu       sync.Mutex
	running  bool
	cancel   context.CancelFunc
	failures int
}

// Start launches the goroutine; safe to call once. Subsequent Start calls
// while running return ErrIntervalRunnerAlreadyRunning.
func (r *IntervalRunner) Start(ctx context.Context) error {
	r.mu.Lock()
	if r.running {
		r.mu.Unlock()
		return ErrIntervalRunnerAlreadyRunning
	}
	if r.Tick == nil {
		r.mu.Unlock()
		return errors.New("interval runner: Tick is required")
	}
	if r.Interval <= 0 {
		r.Interval = 15 * time.Minute
	}
	if r.MaxBackoff <= 0 {
		r.MaxBackoff = 30 * time.Minute
	}
	r.running = true
	ctx, cancel := context.WithCancel(ctx)
	r.cancel = cancel
	r.mu.Unlock()

	go r.loop(ctx)
	return nil
}

// Stop cancels the runner goroutine. Idempotent.
func (r *IntervalRunner) Stop() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.running {
		return
	}
	r.cancel()
	r.running = false
}

func (r *IntervalRunner) loop(ctx context.Context) {
	defer func() {
		r.mu.Lock()
		r.running = false
		r.mu.Unlock()
	}()
	// First tick fires immediately so the user sees fresh data without a
	// wait. Subsequent ticks honour the configured interval.
	for {
		if err := r.Tick(ctx); err != nil {
			r.failures++
		} else {
			r.failures = 0
		}
		wait := r.Interval
		if r.failures > 0 {
			wait = backoffDuration(r.Interval, r.failures, r.MaxBackoff)
		}
		t := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			t.Stop()
			return
		case <-t.C:
		}
	}
}

func backoffDuration(base time.Duration, failures int, max time.Duration) time.Duration {
	d := base
	for i := 1; i < failures && d < max; i++ {
		d *= 2
	}
	if d > max {
		return max
	}
	return d
}

// ErrIntervalRunnerAlreadyRunning means Start was called twice.
var ErrIntervalRunnerAlreadyRunning = errors.New("interval runner already running")
