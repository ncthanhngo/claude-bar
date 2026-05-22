package briefing

import (
	"fmt"
	"time"

	"github.com/robfig/cron/v3"
)

var cronParser = cron.NewParser(
	cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow,
)

// ParseCron validates a standard 5-field cron expression and returns a
// Schedule that can compute next-fire times.
func ParseCron(expr string) (cron.Schedule, error) {
	if expr == "" {
		return nil, fmt.Errorf("empty cron expression")
	}
	s, err := cronParser.Parse(expr)
	if err != nil {
		return nil, fmt.Errorf("invalid cron %q: %w", expr, err)
	}
	return s, nil
}

// NextRunAt returns the next firing time after `now` for the given expression
// and IANA timezone name. Uses local time when tz is "" or invalid.
func NextRunAt(now time.Time, expr, tz string) (time.Time, error) {
	sched, err := ParseCron(expr)
	if err != nil {
		return time.Time{}, err
	}
	loc := resolveTZ(tz)
	return sched.Next(now.In(loc)), nil
}

// ShouldRun returns true if the briefing for `now` is due:
//   - schedule enabled
//   - lastBriefingDate (YYYY-MM-DD) is strictly older than today's date in tz
//   - the most recent fire time at-or-before now has actually occurred today
func ShouldRun(now time.Time, s Schedule, lastBriefingDate string) bool {
	if !s.Enabled {
		return false
	}
	loc := resolveTZ(s.Timezone)
	today := now.In(loc).Format("2006-01-02")
	if lastBriefingDate == today {
		return false
	}
	sched, err := ParseCron(s.CronExpr)
	if err != nil {
		return false
	}
	// Get the next fire from start-of-today, then check whether `now` has
	// passed it. This avoids needing a "prev" API on cron.Schedule.
	startOfDay := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, loc)
	next := sched.Next(startOfDay)
	return !next.After(now.In(loc))
}

func resolveTZ(tz string) *time.Location {
	if tz == "" {
		return time.Local
	}
	if loc, err := time.LoadLocation(tz); err == nil {
		return loc
	}
	return time.Local
}
