package storage

import (
	"testing"
	"time"
)

func mustTime(t *testing.T, s string) time.Time {
	t.Helper()
	v, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

// TestDateBoundsKeepsTheDayOfEnd is the observed failure: the sleep endpoint
// called with a start date and no end defaults end to time.Now(), and a
// DATE column compared against that instant sees only its calendar day —
// today's session was excluded until midnight.
func TestDateBoundsKeepsTheDayOfEnd(t *testing.T) {
	cases := []struct {
		name       string
		start, end string
		from, to   string
	}{
		{
			name:  "end during the day extends to the next midnight",
			start: "2026-09-11T00:00:00Z", end: "2026-09-14T19:12:00Z",
			from: "2026-09-11T00:00:00Z", to: "2026-09-15T00:00:00Z",
		},
		{
			name:  "end exactly at midnight stays exclusive",
			start: "2026-09-11T00:00:00Z", end: "2026-09-15T00:00:00Z",
			from: "2026-09-11T00:00:00Z", to: "2026-09-15T00:00:00Z",
		},
		{
			name:  "start during the day is floored to its day",
			start: "2026-09-11T05:30:00Z", end: "2026-09-12T00:00:00Z",
			from: "2026-09-11T00:00:00Z", to: "2026-09-12T00:00:00Z",
		},
		{
			name:  "bounds in another zone are read as instants",
			start: "2026-09-11T02:00:00+02:00", end: "2026-09-14T19:00:00-05:00",
			from: "2026-09-11T00:00:00Z", to: "2026-09-15T00:00:00Z",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			from, to := dateBounds(mustTime(t, tc.start), mustTime(t, tc.end))
			if !from.Equal(mustTime(t, tc.from)) {
				t.Errorf("from = %v, want %v", from, tc.from)
			}
			if !to.Equal(mustTime(t, tc.to)) {
				t.Errorf("to = %v, want %v", to, tc.to)
			}
			// pgx encodes the calendar day in the value's location; the
			// bounds must therefore carry UTC, not the process zone.
			if from.Location() != time.UTC || to.Location() != time.UTC {
				t.Errorf("bounds are in %v/%v, want UTC", from.Location(), to.Location())
			}
		})
	}
}
