package briefing

import (
	"testing"
	"time"
)

func TestParseCronValid(t *testing.T) {
	cases := []string{"33 8 * * 1-5", "0 9 * * *", "0 */2 * * *"}
	for _, c := range cases {
		if _, err := ParseCron(c); err != nil {
			t.Errorf("ParseCron(%q) failed: %v", c, err)
		}
	}
}

func TestParseCronInvalid(t *testing.T) {
	cases := []string{"", "99 99 99 99 99", "abc"}
	for _, c := range cases {
		if _, err := ParseCron(c); err == nil {
			t.Errorf("ParseCron(%q) accepted invalid expression", c)
		}
	}
}

func TestShouldRun(t *testing.T) {
	loc, _ := time.LoadLocation("Asia/Saigon")
	mondayAt9 := time.Date(2026, 5, 25, 9, 0, 0, 0, loc) // Mon 09:00 +07
	cfg := Schedule{
		CronExpr: "33 8 * * 1-5",
		Enabled:  true,
		Timezone: "Asia/Saigon",
	}

	tests := []struct {
		name     string
		now      time.Time
		enabled  bool
		lastDate string
		want     bool
	}{
		{"weekday after fire, no prior run", mondayAt9, true, "", true},
		{"weekday before fire", mondayAt9.Add(-2 * time.Hour), true, "", false},
		{"already ran today", mondayAt9, true, "2026-05-25", false},
		{"disabled", mondayAt9, false, "", false},
		{"weekend skip", time.Date(2026, 5, 23, 9, 0, 0, 0, loc), true, "", false}, // Saturday
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			c := cfg
			c.Enabled = tc.enabled
			got := ShouldRun(tc.now, c, tc.lastDate)
			if got != tc.want {
				t.Errorf("ShouldRun = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestNextRunAt(t *testing.T) {
	loc, _ := time.LoadLocation("Asia/Saigon")
	mondayMidnight := time.Date(2026, 5, 25, 0, 0, 0, 0, loc)
	next, err := NextRunAt(mondayMidnight, "33 8 * * 1-5", "Asia/Saigon")
	if err != nil {
		t.Fatalf("NextRunAt: %v", err)
	}
	want := time.Date(2026, 5, 25, 8, 33, 0, 0, loc)
	if !next.Equal(want) {
		t.Errorf("NextRunAt = %v, want %v", next, want)
	}
}
