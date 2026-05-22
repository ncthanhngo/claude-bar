package oauth

import "testing"

func TestRateLimitedError_RendersServerHeaderWhenPresent(t *testing.T) {
	err := &RateLimitedError{RetryAfter: "30"}
	got := err.Error()
	want := "rate limited (retry after 30s)"
	if got != want {
		t.Fatalf("Error() = %q, want %q", got, want)
	}
}

func TestRateLimitedError_FallsBackWhenHeaderMissing(t *testing.T) {
	err := &RateLimitedError{}
	got := err.Error()
	want := "rate limited (retry after ~60s)"
	if got != want {
		t.Fatalf("Error() = %q, want %q (approximate fallback when Retry-After header absent)", got, want)
	}
}
