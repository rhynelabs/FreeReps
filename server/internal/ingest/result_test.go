package ingest

import (
	"testing"
	"time"
)

// TestAddSleepStagesSpansDuplicates exists because a night is built from the
// span a request reports. The first upload of a night can be cut off after
// its stages are committed but before the session is written; the resend is
// all duplicates, and it has to report the span anyway or that night never
// gets a session.
func TestAddSleepStagesSpansDuplicates(t *testing.T) {
	from := time.Date(2026, 9, 13, 22, 0, 0, 0, time.UTC)
	to := from.Add(8 * time.Hour)

	var r Result
	r.AddSleepStages(0, from, to)

	if r.SleepStagesInserted != 0 {
		t.Fatalf("inserted = %d, want 0", r.SleepStagesInserted)
	}
	if !r.SleepStagesFrom.Equal(from) || !r.SleepStagesTo.Equal(to) {
		t.Fatalf("span = [%v, %v], want [%v, %v]", r.SleepStagesFrom, r.SleepStagesTo, from, to)
	}

	earlier := from.Add(-24 * time.Hour)
	r.AddSleepStages(3, earlier, from)
	if r.SleepStagesInserted != 3 {
		t.Fatalf("inserted = %d, want 3", r.SleepStagesInserted)
	}
	if !r.SleepStagesFrom.Equal(earlier) || !r.SleepStagesTo.Equal(to) {
		t.Fatalf("span = [%v, %v], want [%v, %v]", r.SleepStagesFrom, r.SleepStagesTo, earlier, to)
	}
}
