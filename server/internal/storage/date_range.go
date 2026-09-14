package storage

import "time"

// dateBounds maps an instant range [start, end) onto a DATE column: the
// result [from, to) covers every UTC calendar day the range touches, as
// midnight instants that encode as those days.
//
// The columns this serves — sleep_sessions.date, activity_summaries.date —
// are DATE, so Postgres types a bound parameter compared against them as a
// date, and pgx encodes a time.Time bound to a date parameter as the calendar
// day of that instant in its own location, dropping the time of day. Passing
// the instants through unchanged made `date < $2` with end = time.Now() mean
// `date < today`, which hid today's row until midnight: the night that ended
// this morning was on the server but missing from every response that did
// not name an end date.
//
// Days are UTC because the stored dates are: a backfilled sleep session is
// dated by the UTC day of its sleep_end (nightSession). Truncating in UTC
// also keeps the bound independent of the process time zone, which is what
// the encoding reads.
func dateBounds(start, end time.Time) (from, to time.Time) {
	from = start.UTC().Truncate(24 * time.Hour)
	to = end.UTC().Truncate(24 * time.Hour)
	if to.Before(end) {
		to = to.AddDate(0, 0, 1)
	}
	return from, to
}
